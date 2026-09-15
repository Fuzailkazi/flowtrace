import Foundation

/// Where each running agent's transcript is, found once per reading.
///
/// Before this existed, `LiveStateReader` knew how to find a Claude Code
/// transcript and nothing else. A running Codex process therefore had no
/// readable history, fell into the "no transcript" branch, and was reported as
/// `waiting` with no prompt and no age for as long as it ran — on the test
/// machine, a Codex session that had been idle for hours was indistinguishable
/// from one started a second ago. OpenCode was in the same position.
///
/// The three agents keep their history in three completely different shapes, so
/// each gets its own lookup and they are built lazily: a machine with no Codex
/// process never walks the Codex session directory.
struct TranscriptIndex {
    struct Entry {
        var sessionId: String?
        /// When the session file was last written — that is, when the *agent*
        /// last did something.
        var modifiedAt: Date
        /// When a person last said something here. Usually much older than
        /// `modifiedAt`, and the only one of the two that answers "how long
        /// have I been away".
        var lastHumanAt: Date?
        var lastPrompt: String?
        /// The directory the session itself says it was started in, when the
        /// store records one. Used to check the association rather than assume it.
        var recordedDirectory: String?
    }

    var claudeRoot: URL
    var codexRoot: URL
    var openCodeDatabase: URL

    /// How far back to look for a session belonging to a running process.
    /// A process running now whose newest session is older than this has
    /// nothing worth associating — the session belongs to a previous run.
    private let horizon: TimeInterval = 30 * 86_400

    init(
        claudeRoot: URL? = nil,
        codexRoot: URL? = nil,
        openCodeDatabase: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeRoot = claudeRoot ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexRoot = codexRoot ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.openCodeDatabase = openCodeDatabase
            ?? home.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    // MARK: - Claude Code

    /// Claude Code names a directory after the path it was launched in, so the
    /// lookup is a single `stat` of a predictable place.
    ///
    /// Two paths are tried, in order: the process's own working directory, then
    /// the repository root. The fallback is what fixes an agent launched in
    /// `repo/packages/api`, whose transcripts live under the slug for that
    /// subdirectory when it was started there, and under the repository's slug
    /// when it was not. Without it such an agent silently had no history.
    func claude(workingDirectory: String, repositoryRoot: String?) -> Entry? {
        var candidates = [workingDirectory]
        if let repositoryRoot, repositoryRoot != workingDirectory {
            candidates.append(repositoryRoot)
        }
        for candidate in candidates {
            let slug = ClaudeCodeAdapter.projectSlug(for: candidate)
            if let entry = newestJSONL(in: claudeRoot.appendingPathComponent(slug)) {
                return entry
            }
        }
        return nil
    }

    private func newestJSONL(in directory: URL) -> Entry? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        let newest = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let meta = FileMeta.stat(url.path) else { return nil }
                return (url, meta.modifiedAt)
            }
            .max { $0.1 < $1.1 }

        guard let (url, modifiedAt) = newest else { return nil }
        let turn = ClaudeTail.lastTurn(in: url.path)
        return Entry(
            sessionId: url.deletingPathExtension().lastPathComponent,
            modifiedAt: modifiedAt,
            lastHumanAt: turn?.at,
            lastPrompt: TranscriptTail.present(turn?.text),
            recordedDirectory: nil
        )
    }

    // MARK: - Codex

    /// Codex files rollouts by date, not by path, so the only way to know which
    /// one belongs to a directory is to open each and read its first line —
    /// which is exactly one line, the `session_meta` record carrying `cwd`.
    ///
    /// Built once per reading and only when a Codex process is running.
    private static func buildCodexIndex(root: URL, horizon: TimeInterval) -> [String: Entry] {
        let cutoff = Date().addingTimeInterval(-horizon)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var newestByDirectory: [String: Entry] = [:]
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let meta = FileMeta.stat(url.path), meta.modifiedAt >= cutoff,
                  var reader = LineReader(path: url.path),
                  let first = reader.next(),
                  let data = first.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String
            else { continue }

            let key = FilePathCanon.canonical(cwd)
            if let existing = newestByDirectory[key], existing.modifiedAt >= meta.modifiedAt {
                continue
            }
            let turn = CodexTail.lastTurn(in: url.path)
            newestByDirectory[key] = Entry(
                // Older rollouts carry only `id`; newer ones carry both.
                sessionId: (payload["session_id"] as? String) ?? (payload["id"] as? String),
                modifiedAt: meta.modifiedAt,
                lastHumanAt: turn?.at,
                lastPrompt: TranscriptTail.present(turn?.text),
                recordedDirectory: key
            )
        }
        return newestByDirectory
    }

    /// Lazily built, so the walk happens at most once and only when needed.
    private final class CodexCache: @unchecked Sendable {
        var index: [String: Entry]?
    }
    private let codexCache = CodexCache()

    func codex(workingDirectory: String, repositoryRoot: String?) -> Entry? {
        let index: [String: Entry]
        if let cached = codexCache.index {
            index = cached
        } else {
            index = Self.buildCodexIndex(root: codexRoot, horizon: horizon)
            codexCache.index = index
        }

        // Exact directory first. A Codex session records the directory it was
        // started in, and matching that exactly is the only association that is
        // certainly right.
        let cwd = FilePathCanon.canonical(workingDirectory)
        if let entry = index[cwd] { return entry }

        // Then the newest session anywhere inside the repository. Less certain,
        // so it is only reached when the exact match fails.
        guard let repositoryRoot else { return nil }
        let root = FilePathCanon.canonical(repositoryRoot)
        return index
            .filter { $0.key == root || $0.key.hasPrefix(root + "/") }
            .values
            .max { $0.modifiedAt < $1.modifiedAt }
    }

    // MARK: - OpenCode

    /// OpenCode keeps its sessions in a SQLite database with a `directory`
    /// column, which makes this the most reliable association of the three —
    /// the store itself says where the work was done, so nothing is inferred
    /// from a file name or a path slug.
    ///
    /// Opened read-only and copied nowhere. A failure to open (the database is
    /// mid-write, or the file does not exist) returns nothing rather than
    /// throwing: no history is a state the row already knows how to show.
    private final class OpenCodeCache: @unchecked Sendable {
        var index: [String: Entry]?
    }
    private let openCodeCache = OpenCodeCache()

    func openCode(workingDirectory: String, repositoryRoot: String?) -> Entry? {
        let index: [String: Entry]
        if let cached = openCodeCache.index {
            index = cached
        } else {
            index = OpenCodeStore.sessionsByDirectory(at: openCodeDatabase)
            openCodeCache.index = index
        }

        let cwd = FilePathCanon.canonical(workingDirectory)
        if let entry = index[cwd] { return entry }
        guard let repositoryRoot else { return nil }
        let root = FilePathCanon.canonical(repositoryRoot)
        return index
            .filter { $0.key == root || $0.key.hasPrefix(root + "/") }
            .values
            .max { $0.modifiedAt < $1.modifiedAt }
    }

    /// The right lookup for an agent.
    func entry(for agent: AgentName, workingDirectory: String, repositoryRoot: String?) -> Entry? {
        switch agent {
        case .codex: codex(workingDirectory: workingDirectory, repositoryRoot: repositoryRoot)
        case .openCode: openCode(workingDirectory: workingDirectory, repositoryRoot: repositoryRoot)
        default: claude(workingDirectory: workingDirectory, repositoryRoot: repositoryRoot)
        }
    }
}

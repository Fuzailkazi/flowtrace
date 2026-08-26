import Foundation

/// Reads Codex CLI transcripts from `~/.codex`.
///
/// Layout: `sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`, whose first line
/// is a `session_meta` record carrying `cwd`. `session_index.jsonl` holds a
/// human-readable `thread_name` per session, which makes a better thread title
/// than anything FlowTrace could infer.
///
/// Read-only.
public struct CodexAdapter: AgentAdapter {
    public let agent: AgentName = .codex
    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private var sessionsRoot: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var indexFile: URL { root.appendingPathComponent("session_index.jsonl") }

    public var searchPaths: [String] { [sessionsRoot.path, indexFile.path] }

    public func discoverSessions(cache: SessionCache? = nil) throws -> [AgentSession] {
        let titles = loadTitles()
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-")
            else { continue }
            files.append(url.path)
        }

        return ConcurrentParse.sessions(in: files) { path in
            guard var session = parse(file: path, cache: cache) else { return nil }
            if session.title == nil { session.title = titles[session.id] }
            return session
        }
    }

    /// `session_index.jsonl` → `{ id: thread_name }`.
    func loadTitles() -> [String: String] {
        guard var reader = LineReader(path: indexFile.path) else { return [:] }
        var titles: [String: String] = [:]
        while let line = reader.next() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String,
                  !name.isEmpty
            else { continue }
            titles[id] = name
        }
        return titles
    }

    func parse(file path: String, cache: SessionCache?) -> AgentSession? {
        guard let meta = FileMeta.stat(path) else { return nil }
        if let cached = cache?.cached(path: path, size: meta.size, modifiedAt: meta.modifiedAt) {
            return cached
        }
        guard var reader = LineReader(path: path) else { return nil }

        var id: String?
        var cwd: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var lastSubstantivePrompt: String?
        var startedAt: Date?
        var lastActivityAt: Date?
        var messageCount = 0

        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            let interesting = line.contains("session_meta") || line.contains("user_message")
            guard interesting else { continue }

            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            if let timestamp = object["timestamp"] as? String,
               let date = ISO8601.parse(timestamp) {
                if startedAt == nil { startedAt = date }
                lastActivityAt = date
            }

            switch object["type"] as? String {
            case "session_meta":
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String
            case "event_msg" where payload["type"] as? String == "user_message":
                guard let text = Self.cleanPrompt(payload["message"] as? String) else { continue }
                messageCount += 1
                if firstPrompt == nil { firstPrompt = text }
                lastPrompt = text
                if AgentSession.isSubstantive(text) { lastSubstantivePrompt = text }
            default:
                break
            }
        }

        // Fall back to the id embedded in the filename when the meta line is absent.
        let resolvedId = id ?? Self.idFromFilename(path)
        guard let resolvedId, cwd != nil || firstPrompt != nil else { return nil }

        let session = AgentSession(
            id: resolvedId,
            agent: .codex,
            cwd: cwd,
            branch: nil,
            title: nil,
            firstPrompt: firstPrompt,
            lastPrompt: lastPrompt,
            lastSubstantivePrompt: lastSubstantivePrompt,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt ?? meta.modifiedAt,
            filePath: path,
            messageCount: messageCount
        )
        cache?.store(session, path: path, size: meta.size, modifiedAt: meta.modifiedAt)
        return session
    }

    /// `rollout-2026-06-27T10-02-42-019f0759-eefc-....jsonl` → the trailing UUID.
    static func idFromFilename(_ path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    /// Codex replays environment and AGENTS.md blocks as user turns; those are
    /// not things the user typed, so they never become a thread's intent.
    static func cleanPrompt(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        if value.hasPrefix("<") { return nil }
        if value.hasPrefix("# AGENTS.md") { return nil }
        if value.count > 4000 { value = String(value.prefix(4000)) }
        return value
    }
}

import Foundation

/// Reads Claude Code transcripts from `~/.claude/projects`.
///
/// Layout: one directory per project (the working directory with `/` replaced by
/// `-`), containing one `<sessionId>.jsonl` per session. Each line is a JSON
/// object; `cwd`, `gitBranch` and `timestamp` ride along on most of them, and an
/// `ai-title` line carries the title Claude generated for the session.
///
/// Read-only. FlowTrace never writes to these files.
public struct ClaudeCodeAdapter: AgentAdapter {
    public let agent: AgentName = .claudeCode
    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var searchPaths: [String] { [root.path] }

    public func discoverSessions(cache: SessionCache? = nil) throws -> [AgentSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var files: [String] = []
        for dir in projectDirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            files.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" }.map(\.path))
        }
        return ConcurrentParse.sessions(in: files) { parse(file: $0, cache: cache) }
    }

    func parse(file path: String, cache: SessionCache?) -> AgentSession? {
        guard let meta = FileMeta.stat(path) else { return nil }
        if let cached = cache?.cached(path: path, size: meta.size, modifiedAt: meta.modifiedAt) {
            return cached
        }
        guard var reader = LineReader(path: path) else { return nil }

        let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var cwd: String?
        var branch: String?
        var title: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var lastSubstantivePrompt: String?
        var startedAt: Date?
        var lastActivityAt: Date?
        var messageCount = 0

        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            // Cheap prefilter — most lines are assistant turns we don't need.
            let interesting = line.contains("\"cwd\"")
                || line.contains("\"type\":\"user\"")
                || line.contains("\"ai-title\"")
            guard interesting else { continue }

            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
            if let value = object["gitBranch"] as? String, !value.isEmpty, value != "HEAD" {
                branch = value
            }
            if let timestamp = object["timestamp"] as? String,
               let date = ISO8601.parse(timestamp) {
                if startedAt == nil { startedAt = date }
                lastActivityAt = date
            }

            switch object["type"] as? String {
            case "ai-title":
                if let value = object["aiTitle"] as? String, !value.isEmpty { title = value }
            case "user":
                guard object["isSidechain"] as? Bool != true else { continue }
                // `isMeta` marks content Claude Code injected on the user's
                // behalf — skill bodies, slash-command expansions. It looks like
                // a user turn but nobody typed it.
                guard object["isMeta"] as? Bool != true else { continue }
                guard let text = Self.userText(from: object["message"]) else { continue }
                messageCount += 1
                if firstPrompt == nil { firstPrompt = text }
                lastPrompt = text
                if AgentSession.isSubstantive(text) { lastSubstantivePrompt = text }
            default:
                break
            }
        }

        guard cwd != nil || firstPrompt != nil else { return nil }

        let session = AgentSession(
            id: sessionId,
            agent: .claudeCode,
            cwd: cwd,
            branch: branch,
            title: title,
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

    /// Pulls the human's words out of a user line, skipping the ones that aren't
    /// actually something the user typed: tool results, injected system reminders,
    /// and interruption markers.
    static func userText(from message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }

        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        }

        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }

        if value.hasPrefix("<") { return nil }                       // system-reminder / command blocks
        if value.hasPrefix("[Request interrupted") { return nil }
        if value.hasPrefix("Caveat: The messages below") { return nil }
        if value.hasPrefix("/") , !value.contains(" ") { return nil } // bare slash command

        if value.count > 4000 { value = String(value.prefix(4000)) }
        return value
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}

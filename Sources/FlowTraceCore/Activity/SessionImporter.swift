import Foundation

/// Folds coding-agent sessions into the day.
///
/// The recorder can see that Claude Code was frontmost, but not what the
/// conversation was about — that only exists in the transcript, and only after
/// the fact. This reads those transcripts and places each session on the timeline
/// at the time it actually happened, with what it was about.
public struct SessionImporter: Sendable {
    private let claude: ClaudeCodeAdapter
    private let codex: CodexAdapter
    private let git: GitProbe

    public init(
        claude: ClaudeCodeAdapter = ClaudeCodeAdapter(),
        codex: CodexAdapter = CodexAdapter(),
        git: GitProbe = GitProbe()
    ) {
        self.claude = claude
        self.codex = codex
        self.git = git
    }

    /// Imports every session that touched a given day. Safe to call repeatedly —
    /// each session is keyed by its own id, so re-importing updates rather than
    /// duplicates.
    @discardableResult
    public func importSessions(
        on day: Date, into store: Store, cache: SessionCache? = nil
    ) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }

        var sessions: [AgentSession] = []
        if claude.isAvailable {
            sessions += (try? claude.discoverSessions(cache: cache)) ?? []
        }
        if codex.isAvailable {
            // Two days of slack, so a session that began late last night and ran
            // past midnight is still found.
            sessions += (try? codex.discoverSessions(modifiedWithin: 2, cache: cache)) ?? []
        }

        let onThisDay = sessions.filter { session in
            guard let at = session.lastActivityAt ?? session.startedAt else { return false }
            return at >= start && at < end
        }

        var imported = 0
        for session in onThisDay {
            guard let event = event(for: session) else { continue }
            if (try? store.upsertImportedActivity(event)) != nil { imported += 1 }
        }
        return imported
    }

    /// The home directory has a last path component too — the user's short name —
    /// and labelling a session "fu2ail" tells them nothing.
    public static func folderLabel(for path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if FilePathCanon.canonical(path) == FilePathCanon.canonical(home) { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func event(for session: AgentSession) -> ActivityEvent? {
        // A session resumed over several days has a first timestamp a week before
        // its last, and calling that a 181-hour span is nonsense. What belongs on
        // a day is the moment you were last in it, as a point rather than a span.
        guard let moment = session.lastActivityAt ?? session.startedAt else { return nil }

        // The repository is what makes a session recognisable — far more than the
        // path the agent happened to be launched from.
        var target = session.cwd.map { Self.folderLabel(for: $0) }
        if let cwd = session.cwd, let top = git.topLevel(of: cwd) {
            target = Self.folderLabel(for: top)
        }

        var metadata: [String: String] = [:]
        if let title = session.title, !title.isEmpty { metadata["about"] = title }
        if session.messageCount > 0 { metadata["messages"] = String(session.messageCount) }
        if let cwd = session.cwd { metadata["cwd"] = cwd }

        // Prompts are free text and can contain pasted credentials, so they are
        // redacted before being stored anywhere near the UI.
        let arc = session.recentPrompts
            .map(AgentSession.withoutLeadingPath)
            .map { Redaction.redact($0) }
            .filter { !Redaction.isOnlyRedactions($0) && !$0.isEmpty }
            .map { AgentSession.condense($0.text, limit: 120) }
        if !arc.isEmpty {
            metadata["asked"] = arc.suffix(3).joined(separator: "\n")
        }

        return ActivityEvent(
            kind: .agentSession,
            startedAt: moment,
            endedAt: moment,
            appName: session.agent.label,
            target: target,
            metadata: metadata,
            externalId: "\(session.agent.rawValue):\(session.id)"
        )
    }
}

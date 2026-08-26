import Foundation

public struct BriefConfig: Sendable {
    /// Below this, you were just here and still remember. Injecting a brief would
    /// be noise, and a hook that produces noise gets uninstalled.
    public var quietHours: Double = 2
    /// Past this, the work isn't paused, it's over.
    public var staleDays: Int = 120
    /// How far back to look for Codex sessions, which aren't indexed by path.
    public var codexLookbackDays: Int = 30
    public var maxPrompts: Int = 3
    public var noisePathFragments: [String] = DetectorConfig().noisePathFragments

    public init() {}
}

/// Assembles the brief for one repository from git state and agent transcripts.
///
/// Reads only what the machine already wrote down. No permissions, no capture, no
/// network — which is what lets this ship as a plugin anyone can install rather
/// than an app they must trust.
public struct BriefBuilder: Sendable {
    private let git: GitProbe
    private let claude: ClaudeCodeAdapter
    private let codex: CodexAdapter

    public init(
        git: GitProbe = GitProbe(),
        claude: ClaudeCodeAdapter = ClaudeCodeAdapter(),
        codex: CodexAdapter = CodexAdapter()
    ) {
        self.git = git
        self.claude = claude
        self.codex = codex
    }

    /// Returns nil when there is nothing worth saying — see the silence rules in
    /// `BriefConfig`. Silence is the common case and the correct one.
    public func build(
        repositoryPath: String,
        config: BriefConfig = BriefConfig(),
        cache: SessionCache? = nil
    ) -> ResumeBrief? {
        guard let state = git.probe(repositoryPath) else { return nil }

        let lowered = state.topLevel.lowercased()
        guard !config.noisePathFragments.contains(where: { lowered.contains($0.lowercased()) })
        else { return nil }

        let sessions = recentSessions(for: state.topLevel, config: config, cache: cache)
        let lastActivity = [state.headDate, sessions.last?.lastActivityAt]
            .compactMap { $0 }
            .max()

        guard let lastActivity else { return nil }

        let elapsed = Date().timeIntervalSince(lastActivity)
        let hours = Int(elapsed / 3600)
        let days = Int(elapsed / 86_400)

        // You were here an hour ago. You know what you were doing.
        guard elapsed >= config.quietHours * 3600 else { return nil }
        guard days <= config.staleDays else { return nil }

        // Nothing outstanding and nothing recent to recall — there is no thread to
        // pick up, so say nothing rather than narrating a tidy repository.
        let hasLooseEnds = state.isDirty || state.commitsAhead > 0
        guard hasLooseEnds || !sessions.isEmpty else { return nil }

        let (prompts, redactions) = promptArc(from: sessions, limit: config.maxPrompts)

        // A brief with no state and no recallable prompts is just a repository
        // name and a date. Not worth a single token of the user's context.
        guard hasLooseEnds || !prompts.isEmpty else { return nil }

        return ResumeBrief(
            repositoryName: state.repositoryName,
            repositoryPath: state.topLevel,
            branch: state.branch,
            daysSinceActivity: days,
            hoursSinceActivity: hours,
            changedFiles: state.changedFiles,
            uncommittedCount: state.dirtyFileCount,
            unpushedCount: state.commitsAhead,
            lastCommitSubject: state.lastCommitSubject,
            recentPrompts: prompts,
            sessionTitle: sessions.last(where: { !($0.title ?? "").isEmpty })?.title,
            redactionCount: redactions
        )
    }

    // MARK: - Sessions

    /// Oldest-first sessions whose working directory resolves to this repository.
    ///
    /// The directory-name filter narrows the candidates cheaply; the git top-level
    /// check is what makes the result correct, since a slug can collide.
    private func recentSessions(
        for repositoryPath: String, config: BriefConfig, cache: SessionCache?
    ) -> [AgentSession] {
        var found: [AgentSession] = []

        if claude.isAvailable,
           let scoped = try? claude.discoverSessions(inRepository: repositoryPath, cache: cache) {
            found.append(contentsOf: scoped)
        }
        if codex.isAvailable,
           let recent = try? codex.discoverSessions(
               modifiedWithin: config.codexLookbackDays, cache: cache
           ) {
            found.append(contentsOf: recent.filter { session in
                guard let cwd = session.cwd else { return false }
                return git.topLevel(of: cwd) == repositoryPath
            })
        }

        return found.sorted {
            ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
        }
    }

    /// The last few things the user actually asked, redacted, oldest first.
    private func promptArc(
        from sessions: [AgentSession], limit: Int
    ) -> (prompts: [String], redactions: Int) {
        var collected: [String] = []
        var redactions = 0

        for session in sessions.suffix(3) {
            for prompt in session.recentPrompts {
                let cleaned = AgentSession.withoutLeadingPath(prompt)
                guard cleaned.count >= 12 else { continue }

                let result = Redaction.redact(cleaned)
                redactions += result.redactionCount
                // A prompt that was only a pasted key tells you nothing about the
                // work, and "[api key removed]" is not a memory aid.
                guard !Redaction.isOnlyRedactions(result), !result.isEmpty else { continue }

                collected.append(AgentSession.condense(result.text, limit: 120))
            }
        }

        // Consecutive duplicates are common — the same ask rephrased.
        var deduped: [String] = []
        for prompt in collected where deduped.last != prompt {
            deduped.append(prompt)
        }
        return (Array(deduped.suffix(limit)), redactions)
    }
}

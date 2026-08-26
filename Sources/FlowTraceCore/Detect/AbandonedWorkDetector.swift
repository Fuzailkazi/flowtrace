import Foundation

public struct DetectorConfig: Sendable {
    /// How long a piece of work must sit untouched before it counts as cold.
    public var coldDays: Int = 7
    /// Ignore sessions older than this when attributing work to a repository.
    public var lookbackDays: Int = 240
    public var maxProposals: Int = 40
    public var minScore: Double = 1.0

    public init(
        coldDays: Int = 7,
        lookbackDays: Int = 240,
        maxProposals: Int = 40,
        minScore: Double = 1.0
    ) {
        self.coldDays = coldDays
        self.lookbackDays = lookbackDays
        self.maxProposals = maxProposals
        self.minScore = minScore
    }
}

public struct ScanProgress: Sendable {
    public var phase: String
    public var completed: Int
    public var total: Int
}

public struct ScanResult: Sendable {
    public var proposals: [ThreadProposal]
    public var sessionsScanned: Int
    public var repositoriesProbed: Int
    /// Working directories from sessions that no longer exist on disk.
    public var missingPaths: Int
    public var duration: TimeInterval
}

/// Finds work that was started and never finished.
///
/// The whole point of FlowTrace is that this runs before the user types anything.
/// It reads agent transcripts and git state, both read-only, and produces ranked
/// proposals — each carrying the raw evidence that justified it. Nothing here
/// writes a thread; the user confirms every proposal before it becomes one.
public final class AbandonedWorkDetector {
    private let adapters: [any AgentAdapter]
    private let git: GitProbe
    private let cache: SessionCache?
    private let ignoredPaths: Set<String>

    public init(
        adapters: [any AgentAdapter] = [ClaudeCodeAdapter(), CodexAdapter()],
        git: GitProbe = GitProbe(),
        cache: SessionCache? = nil,
        ignoredPaths: Set<String> = []
    ) {
        self.adapters = adapters
        self.git = git
        self.cache = cache
        // Ignore entries may have been stored from a folder picker or a CLI
        // argument, which can spell the same directory differently from git.
        self.ignoredPaths = FilePathCanon.canonical(ignoredPaths)
    }

    public func scan(
        config: DetectorConfig = DetectorConfig(),
        progress: ((ScanProgress) -> Void)? = nil
    ) throws -> ScanResult {
        let started = Date()

        // 1. Read every discoverable agent session.
        progress?(ScanProgress(phase: "Reading agent sessions", completed: 0, total: adapters.count))
        var sessions: [AgentSession] = []
        for (index, adapter) in adapters.enumerated() where adapter.isAvailable {
            sessions.append(contentsOf: (try? adapter.discoverSessions(cache: cache)) ?? [])
            progress?(ScanProgress(
                phase: "Reading \(adapter.agent.label) sessions",
                completed: index + 1, total: adapters.count
            ))
        }

        let cutoff = Calendar.current.date(
            byAdding: .day, value: -config.lookbackDays, to: Date()
        ) ?? .distantPast
        let recent = sessions.filter { ($0.lastActivityAt ?? .distantPast) >= cutoff }

        // 2. Collapse working directories onto their repository roots. Several
        //    subfolders of one monorepo are one piece of work, not several.
        //
        //    Each resolution is a `git rev-parse`, so the unique directories are
        //    resolved concurrently — this is the bulk of a cold scan.
        let uniqueCwds = Array(Set(recent.compactMap(\.cwd)))
        progress?(ScanProgress(phase: "Resolving repositories", completed: 0, total: uniqueCwds.count))

        var topLevelByCwd: [String: String] = [:]
        let resolveLock = NSLock()
        var resolved = 0
        DispatchQueue.concurrentPerform(iterations: uniqueCwds.count) { index in
            let cwd = uniqueCwds[index]
            let top = git.topLevel(of: cwd)
            resolveLock.lock()
            if let top { topLevelByCwd[cwd] = top }
            resolved += 1
            let done = resolved
            resolveLock.unlock()
            if done % 8 == 0 {
                progress?(ScanProgress(
                    phase: "Resolving repositories", completed: done, total: uniqueCwds.count
                ))
            }
        }

        var repoSessions: [String: [AgentSession]] = [:]
        var missingPaths = 0
        for session in recent {
            guard let cwd = session.cwd else { continue }
            guard let top = topLevelByCwd[cwd] else { missingPaths += 1; continue }
            guard !ignoredPaths.contains(top) else { continue }
            repoSessions[top, default: []].append(session)
        }

        // 3. Probe git state once per repository and score it, again concurrently.
        progress?(ScanProgress(phase: "Checking git state", completed: 0, total: repoSessions.count))
        let repos = Array(repoSessions)
        var proposals: [ThreadProposal] = []
        let scoreLock = NSLock()
        var probed = 0
        DispatchQueue.concurrentPerform(iterations: repos.count) { index in
            let (repoPath, group) = repos[index]
            let proposal = evaluate(repoPath: repoPath, sessions: group, config: config)
            scoreLock.lock()
            if let proposal { proposals.append(proposal) }
            probed += 1
            let done = probed
            scoreLock.unlock()
            progress?(ScanProgress(
                phase: "Checking git state", completed: done, total: repos.count
            ))
        }

        proposals.sort { $0.score > $1.score }

        return ScanResult(
            proposals: Array(proposals.prefix(config.maxProposals)),
            sessionsScanned: sessions.count,
            repositoriesProbed: repoSessions.count,
            missingPaths: missingPaths,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Scoring

    func evaluate(repoPath: String, sessions: [AgentSession], config: DetectorConfig) -> ThreadProposal? {
        guard let state = git.probe(repoPath) else { return nil }

        let ordered = sessions.sorted {
            ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
        }
        guard let newest = ordered.last else { return nil }

        // Cold is measured from the last thing that happened, whichever it was:
        // a commit or an agent session.
        let lastActivity = [state.headDate, newest.lastActivityAt]
            .compactMap { $0 }
            .max() ?? Date.distantPast
        let daysCold = max(0, Calendar.current.dateComponents(
            [.day], from: lastActivity, to: Date()
        ).day ?? 0)

        // Something must actually be unfinished. A clean, pushed, cold repo is
        // not abandoned work — it is finished work.
        let hasLooseEnds = state.isDirty || state.commitsAhead > 0
        guard hasLooseEnds, daysCold >= config.coldDays else { return nil }

        var score = 0.0
        score += min(Double(state.dirtyFileCount), 20) * 0.25
        score += min(Double(daysCold) / 7.0, 6) * 0.6
        score += min(Double(state.commitsAhead), 10) * 0.3
        score += min(Double(sessions.count), 5) * 0.2
        if Self.looksUnfinished(newest.resumePrompt) { score += 1.0 }

        guard score >= config.minScore else { return nil }

        let agents = Array(Set(sessions.map(\.agent))).sorted { $0.rawValue < $1.rawValue }
        let evidence = DetectionEvidence(
            repositoryPath: state.topLevel,
            repositoryName: state.repositoryName,
            branch: state.branch,
            dirtyFileCount: state.dirtyFileCount,
            daysSinceLastCommit: state.daysSinceLastCommit,
            unpushedCommitCount: state.commitsAhead,
            sessionCount: sessions.count,
            agents: agents,
            lastPrompt: newest.resumePrompt.map { AgentSession.condense($0, limit: 240) },
            lastSessionAt: newest.lastActivityAt
        )

        return ThreadProposal(
            repositoryPath: state.topLevel,
            branch: state.branch,
            suggestedTitle: Self.title(for: ordered, state: state),
            suggestedIntent: ordered.first?.firstPrompt.map { AgentSession.condense($0, limit: 240) } ?? "",
            suggestedNextStep: newest.resumePrompt.map { AgentSession.condense($0, limit: 240) } ?? "",
            score: score,
            evidence: evidence
        )
    }

    /// Prefer the title the agent wrote for itself — it describes the work better
    /// than a repository name can. `ordered` is oldest-first; the most recent
    /// session that has a title wins.
    static func title(for ordered: [AgentSession], state: GitState) -> String {
        if let titled = ordered.last(where: { !($0.title ?? "").isEmpty }), let title = titled.title {
            return "\(title) · \(state.repositoryName)"
        }
        // A long first prompt makes a bad title — fall back to the repository.
        if let first = ordered.first?.firstPrompt, first.count <= 60 {
            return AgentSession.condense(first, limit: 60)
        }
        let branch = state.branch
        let isDefault = branch == "main" || branch == "master" || branch == "HEAD"
        if isDefault || branch.count > 24 { return state.repositoryName }
        return "\(state.repositoryName) · \(branch)"
    }

    /// Weak signal that the last instruction was mid-task. It only nudges the
    /// ranking — it never decides on its own whether something is abandoned.
    static func looksUnfinished(_ prompt: String?) -> Bool {
        guard let prompt = prompt?.lowercased() else { return false }
        let markers = [
            "now ", "next", "also ", "then ", "continue", "keep going", "finish",
            "add ", "fix ", "implement", "refactor", "update ", "make it", "try ",
        ]
        return markers.contains { prompt.hasPrefix($0) || prompt.contains(" \($0)") }
    }
}

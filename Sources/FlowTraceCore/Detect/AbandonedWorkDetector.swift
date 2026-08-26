import Foundation

public struct DetectorConfig: Sendable {
    /// Work touched more recently than this is still in flight — you don't need
    /// reminding about what you did yesterday.
    public var coldDays: Int = 2

    /// Past this, work isn't paused, it's over. Surfacing six-month-old repos
    /// turns the list into a guilt pile nobody acts on.
    public var deadDays: Int = 90

    /// Where the value peaks: long enough to have lost the thread, recent enough
    /// that you still care.
    public var peakDays: Double = 10

    /// Ignore sessions older than this when attributing work to a repository.
    public var lookbackDays: Int = 240
    public var maxProposals: Int = 40
    public var minScore: Double = 1.0

    /// Path fragments that mean "not a project of mine": agent scratch worktrees,
    /// tutorials, temp checkouts. These generate transcripts and dirty files but
    /// are never work you intend to resume.
    public var noisePathFragments: [String] = [
        "/conductor/workspaces/",
        "/.worktrees/",
        "/starter project/",
        "/node_modules/",
        "/private/var/folders/",
        "/var/folders/",
        "/.Trash/",
    ]

    public init(
        coldDays: Int = 2,
        deadDays: Int = 90,
        peakDays: Double = 10,
        lookbackDays: Int = 240,
        maxProposals: Int = 40,
        minScore: Double = 1.0,
        noisePathFragments: [String]? = nil
    ) {
        self.coldDays = coldDays
        self.deadDays = deadDays
        self.peakDays = peakDays
        self.lookbackDays = lookbackDays
        self.maxProposals = maxProposals
        self.minScore = minScore
        if let noisePathFragments { self.noisePathFragments = noisePathFragments }
    }

    func isNoise(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return noisePathFragments.contains { lowered.contains($0.lowercased()) }
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

        // Something must actually be unfinished. A clean, pushed repo is not
        // paused work — it is finished work.
        let hasLooseEnds = state.isDirty || state.commitsAhead > 0
        guard hasLooseEnds else { return nil }

        // Touched today? You haven't lost the thread yet. Untouched for months?
        // You're not coming back, and saying so is just a reproach.
        guard daysCold >= config.coldDays, daysCold <= config.deadDays else { return nil }
        guard !config.isNoise(state.topLevel) else { return nil }

        // A working tree dirty only with lockfiles and build output is not work
        // left half-done — it is what `npm install` did on your way past. Without
        // some other sign of intent, there is nothing here to resume.
        let meaningfulEdits = state.changedFiles.filter { !DetectionEvidence.isGenerated($0) }
        let onlyGeneratedEdits = state.dirtyFileCount > 0 && meaningfulEdits.isEmpty
        let hasIntentSignal = !newest.recentPrompts.isEmpty || state.commitsAhead > 0
        if onlyGeneratedEdits, !hasIntentSignal { return nil }

        var score = Self.recencyScore(daysCold: daysCold, peak: config.peakDays)
        if onlyGeneratedEdits { score -= 1.0 }
        score += min(Double(meaningfulEdits.count), 20) * 0.15
        score += min(Double(state.commitsAhead), 10) * 0.35
        score += min(Double(sessions.count), 5) * 0.2
        if Self.looksUnfinished(newest.resumePrompt) { score += 0.75 }
        // Work you can recognise at a glance is worth surfacing above work you can't.
        if state.lastCommitSubject != nil { score += 0.25 }
        if !newest.recentPrompts.isEmpty { score += 0.25 }

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
            lastSessionAt: newest.lastActivityAt,
            changedFiles: state.changedFiles,
            lastCommitSubject: state.lastCommitSubject,
            promptArc: newest.recentPrompts
                .map(AgentSession.withoutLeadingPath)
                .filter { $0.count >= 12 }
                .suffix(3)
                .map { AgentSession.condense($0, limit: 110) },
            sessionTitle: ordered.last(where: { !($0.title ?? "").isEmpty })?.title
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

    /// The repository is what you recognise; a session title is a transient task.
    ///
    /// An earlier version led with the agent's own title, which produced entries
    /// like "Check current git branch" standing in for an entire product. The repo
    /// name and branch identify the work; the session title describes what you were
    /// doing inside it, and belongs underneath.
    static func title(for ordered: [AgentSession], state: GitState) -> String {
        let branch = state.branch
        let isDefault = branch == "main" || branch == "master" || branch == "HEAD"
        if isDefault || branch.count > 28 { return state.repositoryName }
        return "\(state.repositoryName) · \(branch)"
    }

    /// Value peaks a week or two out: long enough to have lost the thread, recent
    /// enough that you still care. A bell curve rather than the old linear ramp,
    /// which rewarded staleness and pushed dead repos to the top.
    static func recencyScore(daysCold: Int, peak: Double) -> Double {
        let spread = 18.0
        let offset = (Double(daysCold) - peak) / spread
        return 3.0 * exp(-offset * offset)
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

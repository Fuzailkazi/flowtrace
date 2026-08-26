import Foundation

/// Exactly what FlowTrace observed on disk to justify proposing a thread.
///
/// This is stored verbatim and surfaced in the UI. The product principle is that
/// trust matters more than automation: the user must always be able to see why
/// something was proposed, without taking FlowTrace's word for it.
public struct DetectionEvidence: Codable, Hashable, Sendable {
    public var repositoryPath: String
    public var repositoryName: String
    public var branch: String
    /// Number of uncommitted files at scan time.
    public var dirtyFileCount: Int
    /// Whole days since the most recent commit.
    public var daysSinceLastCommit: Int
    /// Commits on this branch not present on its upstream, if there is one.
    public var unpushedCommitCount: Int
    /// How many agent sessions referenced this repository.
    public var sessionCount: Int
    public var agents: [AgentName]
    /// The last thing the user asked an agent to do here — verbatim, truncated.
    public var lastPrompt: String?
    public var lastSessionAt: Date?
    public var scoredAt: Date

    /// The files you were editing. More recognisable than any count.
    public var changedFiles: [String]
    /// Your own description of the last thing that landed.
    public var lastCommitSubject: String?
    /// The last few things you asked here, oldest first.
    public var promptArc: [String]
    /// The title the agent gave the session. Describes what you were doing inside
    /// the repository — useful as a subtitle, misleading as an identity.
    public var sessionTitle: String?

    public init(
        repositoryPath: String,
        repositoryName: String,
        branch: String,
        dirtyFileCount: Int,
        daysSinceLastCommit: Int,
        unpushedCommitCount: Int,
        sessionCount: Int,
        agents: [AgentName],
        lastPrompt: String? = nil,
        lastSessionAt: Date? = nil,
        scoredAt: Date = Date(),
        changedFiles: [String] = [],
        lastCommitSubject: String? = nil,
        promptArc: [String] = [],
        sessionTitle: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.repositoryName = repositoryName
        self.branch = branch
        self.dirtyFileCount = dirtyFileCount
        self.daysSinceLastCommit = daysSinceLastCommit
        self.unpushedCommitCount = unpushedCommitCount
        self.sessionCount = sessionCount
        self.agents = agents
        self.lastPrompt = lastPrompt
        self.lastSessionAt = lastSessionAt
        self.scoredAt = scoredAt
        self.changedFiles = changedFiles
        self.lastCommitSubject = lastCommitSubject
        self.promptArc = promptArc
        self.sessionTitle = sessionTitle
    }

    /// Files that were generated rather than written. They show up in `git status`
    /// constantly and tell you nothing about what you were building.
    static func isGenerated(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let lowered = path.lowercased()

        let generatedNames: Set<String> = [
            "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb",
            "cargo.lock", "poetry.lock", "gemfile.lock", "composer.lock",
            "package.json", ".ds_store", "next-env.d.ts",
        ]
        if generatedNames.contains(name) { return true }

        let generatedDirs = ["/dist/", "/build/", "/.next/", "/node_modules/",
                             "/vendor/", "/target/", "/coverage/", "/.venv/"]
        if generatedDirs.contains(where: { lowered.contains($0) }) { return true }

        return name.hasSuffix(".min.js") || name.hasSuffix(".map") || name.hasSuffix(".d.ts")
    }

    /// A short, recognisable list of what you were touching.
    ///
    /// Source files first — those are the ones that make you say "oh, *that*".
    /// Generated files are only mentioned if there is nothing else to show.
    public var fileSummary: String? {
        guard !changedFiles.isEmpty else { return nil }

        let meaningful = changedFiles.filter { !Self.isGenerated($0) }
        let pool = meaningful.isEmpty ? changedFiles : meaningful

        let names = pool.prefix(4).map { ($0 as NSString).lastPathComponent }
        let extra = changedFiles.count - names.count
        let summary = names.joined(separator: ", ") + (extra > 0 ? " +\(extra) more" : "")

        return meaningful.isEmpty ? summary + " (generated only)" : summary
    }

    /// Human-readable justification lines, one per observed signal. Rendered
    /// directly on proposal cards and in the thread timeline.
    public var reasons: [String] {
        var out: [String] = []
        if dirtyFileCount > 0 {
            out.append("\(dirtyFileCount) uncommitted file\(dirtyFileCount == 1 ? "" : "s")")
        }
        if unpushedCommitCount > 0 {
            out.append("\(unpushedCommitCount) unpushed commit\(unpushedCommitCount == 1 ? "" : "s")")
        }
        if daysSinceLastCommit > 0 {
            out.append("last commit \(daysSinceLastCommit)d ago")
        }
        if sessionCount > 0 {
            let names = agents.map(\.label).joined(separator: " + ")
            out.append("\(sessionCount) \(names) session\(sessionCount == 1 ? "" : "s")")
        }
        return out
    }
}

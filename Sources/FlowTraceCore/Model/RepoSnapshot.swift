import Foundation
import GRDB

/// Git state for a repository at a moment in time. Successive snapshots are what
/// let the dashboard answer "what changed since I last worked on it?".
public struct RepoSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var repositoryPath: String
    public var branch: String
    public var headSha: String?
    public var dirtyFileCount: Int
    public var commitsAhead: Int
    public var commitsBehind: Int
    public var capturedAt: Date

    public init(
        id: String = UUID().uuidString,
        repositoryPath: String,
        branch: String,
        headSha: String? = nil,
        dirtyFileCount: Int = 0,
        commitsAhead: Int = 0,
        commitsBehind: Int = 0,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.headSha = headSha
        self.dirtyFileCount = dirtyFileCount
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
        self.capturedAt = capturedAt
    }
}

extension RepoSnapshot: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "repoSnapshot"

    public enum Columns {
        public static let repositoryPath = Column("repositoryPath")
        public static let capturedAt = Column("capturedAt")
    }
}

/// The difference between two snapshots of the same repository, rendered as
/// short human-readable lines on a thread card.
public struct RepoChange: Hashable, Sendable {
    public struct BranchChange: Hashable, Sendable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public var branchChanged: BranchChange?
    public var newCommits: Bool
    public var dirtyDelta: Int

    public init(branchChanged: BranchChange? = nil, newCommits: Bool, dirtyDelta: Int) {
        self.branchChanged = branchChanged
        self.newCommits = newCommits
        self.dirtyDelta = dirtyDelta
    }

    public var isEmpty: Bool {
        branchChanged == nil && !newCommits && dirtyDelta == 0
    }

    public var summaryLines: [String] {
        var out: [String] = []
        if let b = branchChanged { out.append("branch \(b.from) → \(b.to)") }
        if newCommits { out.append("new commits since you left") }
        if dirtyDelta > 0 { out.append("\(dirtyDelta) more uncommitted file\(dirtyDelta == 1 ? "" : "s")") }
        if dirtyDelta < 0 { out.append("\(-dirtyDelta) fewer uncommitted file\(dirtyDelta == -1 ? "" : "s")") }
        return out
    }

    public static func between(old: RepoSnapshot, new: RepoSnapshot) -> RepoChange {
        RepoChange(
            branchChanged: old.branch == new.branch
                ? nil
                : BranchChange(from: old.branch, to: new.branch),
            newCommits: old.headSha != new.headSha,
            dirtyDelta: new.dirtyFileCount - old.dirtyFileCount
        )
    }
}

import Foundation
import GRDB

/// One brief that was shown, and what the user thought of it.
public struct BriefLogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// The brief beat what the user would have typed themselves.
        case win
        case loss
    }

    public var id: String
    public var repositoryPath: String
    public var repositoryName: String
    public var estimatedTokens: Int
    public var shownAt: Date
    public var verdict: Verdict?
    public var note: String?
    public var judgedAt: Date?

    public init(
        id: String = UUID().uuidString,
        repositoryPath: String,
        repositoryName: String,
        estimatedTokens: Int = 0,
        shownAt: Date = Date(),
        verdict: Verdict? = nil,
        note: String? = nil,
        judgedAt: Date? = nil
    ) {
        self.id = id
        self.repositoryPath = repositoryPath
        self.repositoryName = repositoryName
        self.estimatedTokens = estimatedTokens
        self.shownAt = shownAt
        self.verdict = verdict
        self.note = note
        self.judgedAt = judgedAt
    }
}

extension BriefLogEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "briefLog"

    public enum Columns {
        public static let shownAt = Column("shownAt")
        public static let verdict = Column("verdict")
    }
}

/// The seven-day test: does an auto-generated brief actually beat the thirty
/// seconds a developer already spends typing "we were fixing the auth redirect,
/// continue"? Nothing else about this product matters until that is answered, so
/// it is recorded rather than remembered.
extension Store {
    @discardableResult
    public func recordBriefShown(
        repositoryPath: String, repositoryName: String, estimatedTokens: Int
    ) throws -> BriefLogEntry {
        var entry = BriefLogEntry(
            repositoryPath: repositoryPath,
            repositoryName: repositoryName,
            estimatedTokens: estimatedTokens
        )
        try database.writer.write { db in try entry.insert(db) }
        return entry
    }

    /// Judges the most recent unjudged brief. Verdicts arrive after the session,
    /// so the newest one still awaiting judgement is the one being talked about.
    @discardableResult
    public func judgeLatestBrief(_ verdict: BriefLogEntry.Verdict, note: String?) throws -> BriefLogEntry? {
        try database.writer.write { db in
            guard var entry = try BriefLogEntry
                .filter(BriefLogEntry.Columns.verdict == nil)
                .order(BriefLogEntry.Columns.shownAt.desc)
                .fetchOne(db)
            else { return nil }

            entry.verdict = verdict
            entry.note = note
            entry.judgedAt = Date()
            try entry.update(db)
            return entry
        }
    }

    public func briefLog(since: Date? = nil) throws -> [BriefLogEntry] {
        try database.writer.read { db in
            var request = BriefLogEntry.order(BriefLogEntry.Columns.shownAt.desc)
            if let since {
                request = request.filter(BriefLogEntry.Columns.shownAt >= since)
            }
            return try request.fetchAll(db)
        }
    }
}

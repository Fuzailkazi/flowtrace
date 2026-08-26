import Foundation
import GRDB

/// Memo of an already-parsed agent session file, keyed by path and invalidated
/// by size or mtime. Rescans only re-read files that actually changed, which is
/// what keeps a full scan under a couple of seconds across hundreds of sessions.
public struct ScanCacheEntry: Codable, Hashable, Sendable {
    public var filePath: String
    public var fileSize: Int64
    public var modifiedAt: Date
    /// The parsed `AgentSession`, JSON-encoded.
    public var payload: String
    public var cachedAt: Date

    public init(
        filePath: String,
        fileSize: Int64,
        modifiedAt: Date,
        payload: String,
        cachedAt: Date = Date()
    ) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.payload = payload
        self.cachedAt = cachedAt
    }
}

extension ScanCacheEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scanCache"

    public enum Columns {
        public static let filePath = Column("filePath")
    }
}

/// A repository or directory the user has told FlowTrace to stop proposing.
public struct IgnoredPath: Codable, Hashable, Sendable {
    public var path: String
    public var reason: String
    public var createdAt: Date

    public init(path: String, reason: String = "", createdAt: Date = Date()) {
        self.path = path
        self.reason = reason
        self.createdAt = createdAt
    }
}

extension IgnoredPath: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ignoredPath"

    public enum Columns {
        public static let path = Column("path")
    }
}

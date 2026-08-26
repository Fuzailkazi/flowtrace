import Foundation
import GRDB

/// Owns the on-disk SQLite database.
///
/// Everything FlowTrace knows lives in one local file. There is no server, no
/// account and no sync. The file is opened in WAL mode so the menubar app and
/// the `flowtrace` CLI can both write to it without stepping on each other.
public final class FlowTraceDatabase {
    public let writer: DatabaseWriter

    /// `~/Library/Application Support/FlowTrace/flowtrace.sqlite`
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FlowTrace", isDirectory: true)
            .appendingPathComponent("flowtrace.sqlite")
    }

    /// Directory holding the database plus the localhost port file.
    public static var supportDirectory: URL {
        defaultURL.deletingLastPathComponent()
    }

    public convenience init(url: URL = FlowTraceDatabase.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        // The CLI may write while the app holds the database open.
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: config)
        try self.init(writer: pool)
    }

    /// In-memory database, used by tests so they never touch the real file.
    public static func inMemory() throws -> FlowTraceDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try FlowTraceDatabase(writer: DatabaseQueue(configuration: config))
    }

    public init(writer: DatabaseWriter) throws {
        self.writer = writer
        try Migrations.migrator.migrate(writer)
    }

    /// Where the database file lives, for display in Settings.
    public var fileURL: URL? {
        (writer as? DatabasePool).map { URL(fileURLWithPath: $0.path) }
    }
}

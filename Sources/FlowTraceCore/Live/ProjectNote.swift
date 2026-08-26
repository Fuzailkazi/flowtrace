import Foundation
import GRDB

/// What you're building in a place, and where you stopped.
///
/// Keyed on the repository rather than on a session or a process, because those
/// end and this shouldn't. Close the terminal, quit the agent, reboot — come back
/// next week and the answer to "what was I doing here" is still written down.
public struct ProjectNote: Codable, Identifiable, Hashable, Sendable {
    public var id: String { repositoryPath }
    public var repositoryPath: String
    public var repositoryName: String

    /// "What am I building?"
    public var building: String
    /// "What's next?"
    public var nextStep: String
    /// Paused work stays visible but stops asking to be explained.
    public var isPaused: Bool
    public var updatedAt: Date

    public init(
        repositoryPath: String,
        repositoryName: String,
        building: String = "",
        nextStep: String = "",
        isPaused: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.repositoryPath = FilePathCanon.canonical(repositoryPath)
        self.repositoryName = repositoryName
        self.building = building
        self.nextStep = nextStep
        self.isPaused = isPaused
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        building.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ProjectNote: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "projectNote"

    public enum Columns {
        public static let repositoryPath = Column("repositoryPath")
        public static let updatedAt = Column("updatedAt")
    }
}

extension Store {
    public func projectNote(for repositoryPath: String) throws -> ProjectNote? {
        let canonical = FilePathCanon.canonical(repositoryPath)
        return try database.writer.read { db in
            try ProjectNote.fetchOne(db, key: canonical)
        }
    }

    public func allProjectNotes() throws -> [ProjectNote] {
        try database.writer.read { db in
            try ProjectNote.order(ProjectNote.Columns.updatedAt.desc).fetchAll(db)
        }
    }

    @discardableResult
    public func saveProjectNote(_ note: ProjectNote) throws -> ProjectNote {
        var note = note
        note.updatedAt = Date()
        try database.writer.write { db in try note.save(db) }
        return note
    }

    public func deleteProjectNote(repositoryPath: String) throws {
        _ = try database.writer.write { db in
            try ProjectNote.deleteOne(db, key: FilePathCanon.canonical(repositoryPath))
        }
    }
}

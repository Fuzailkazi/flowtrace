import Foundation
import GRDB

/// Putting what the user actually remembers into the index.
///
/// The search index was built around work threads, and the product's idea of a
/// memory moved on without it. What a person writes today is a note on an
/// activity row — `annotate` calls itself "the point of the whole app" — or a
/// note on a project. Neither has ever been indexed, so searching for a
/// sentence you typed yesterday returned nothing, and did so silently.
///
/// This is the missing half of the existing index, not a second one: same
/// table, same tokenizer, same ranking, same explicit-sync design. Only the
/// kinds are new.
enum MemoryIndexing {
    /// A noted activity row, as the index should see it.
    ///
    /// The title is where it happened and the body is why, because `bm25`
    /// weights the title eight times the body. Searching for a project name
    /// should find every memory from that project; searching for a phrase you
    /// wrote should find the one memory that contains it.
    static func index(_ db: Database, event: ActivityEvent) throws {
        // Only rows carrying the user's own words. An ambient span nobody wrote
        // on is not a memory, and indexing every app switch would bury the four
        // sentences somebody actually typed under ten thousand rows.
        guard let note = event.note, !note.isEmpty else {
            try SearchIndex.remove(db, kind: .memory, recordId: event.id)
            return
        }

        try SearchIndex.index(
            db, kind: .memory, recordId: event.id,
            // A memory belongs to no thread. `recordId` is the navigation
            // target for this kind, which is why the app routes on `kind`.
            threadId: "",
            title: title(for: event),
            body: note
        )
    }

    /// Where a memory happened, in the words the rest of the app uses for it.
    static func title(for event: ActivityEvent) -> String {
        // The place the capture resolved beats the app name: "stripe-migration"
        // is what somebody searches for, "FlowTrace" is where they typed it.
        [event.metadata["place"], event.target, event.appName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .first ?? event.appName
    }

    /// A project note — what somebody said they were building somewhere.
    static func index(_ db: Database, note: ProjectNote) throws {
        let body = [note.building, note.nextStep]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        guard !body.isEmpty else {
            try SearchIndex.remove(db, kind: .place, recordId: note.repositoryPath)
            return
        }

        try SearchIndex.index(
            db, kind: .place, recordId: note.repositoryPath, threadId: "",
            title: note.repositoryName, body: body
        )
    }

    /// Indexes every memory already on disk.
    ///
    /// Run once by a migration, and again by the redaction rebuild. Without it
    /// the fix would only apply to notes written after the upgrade, which for
    /// somebody with months of memories is indistinguishable from no fix.
    static func indexEverything(_ db: Database) throws {
        let noted = try ActivityEvent
            .filter(ActivityEvent.Columns.note != nil)
            .fetchAll(db)
        for event in noted { try index(db, event: event) }

        for note in try ProjectNote.fetchAll(db) { try index(db, note: note) }
    }
}

public extension Store {
    /// Rebuilds the index of memories and project notes from what is on disk.
    ///
    /// The migration runs this once. It stays public because an index that can
    /// only be built by upgrading is one that can never be repaired: if a
    /// future write path forgets to index, this is the one call that puts the
    /// database right without touching anybody's memories.
    func reindexMemories() throws {
        try database.writer.write { db in try MemoryIndexing.indexEverything(db) }
    }
}

import Foundation
import FlowTraceCore

/// Finding a memory you wrote.
///
/// The index was built around work threads and never followed the product. What
/// a person writes today is a note on something they were doing, or a note on a
/// project, and neither had ever reached the index — so searching for a
/// sentence you typed yesterday returned nothing, and returned it silently.
/// These are the assertions that would have caught that.
func runMemorySearchTests() {
    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }

    /// A memory, written the way the capture panel writes one.
    @discardableResult
    func remember(
        _ why: String, place: String? = nil, app: String = "Brave",
        into store: Store, at when: Date = Date()
    ) throws -> ActivityEvent {
        let event = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: when, endedAt: when, appName: app,
            target: place, metadata: place.map { ["place": $0] } ?? [:]
        ))
        return try unwrap(try store.annotate(activityId: event.id, note: why))
    }

    TestKit.suite("Indexing what you wrote")

    TestKit.test("a note written now is findable now") {
        let store = try store()
        try remember("waiting on the Stripe webhook docs", place: "billing", into: store)

        let hits = try store.search("webhook")
        expectEqual(hits.count, 1)
        expectEqual(hits.first?.kind, .memory)
        expectEqual(hits.first?.title, "billing", "found under the place it happened")
    }

    // The point of the index over a substring filter: "auth" has to find
    // "authentication", which `contains` does and stemming does better.
    TestKit.test("a partial word finds the whole one") {
        let store = try store()
        try remember("came back to finish the authentication rewrite", into: store)
        expect(!(try store.search("auth").isEmpty))
        expect(!(try store.search("rewrite").isEmpty))
    }

    TestKit.test("the place a memory happened is searchable, not just the words") {
        let store = try store()
        try remember("come back to this", place: "stripe-migration", into: store)
        let hits = try store.search("stripe")
        expectEqual(hits.count, 1, "found by where it happened")
    }

    TestKit.test("a project note is findable by what you said you were building") {
        let store = try store()
        var note = ProjectNote(repositoryPath: "/p/acme", repositoryName: "acme")
        note.building = "the refund pipeline"
        note.nextStep = "wire up the webhook retry"
        try store.saveProjectNote(note)

        expectEqual(try store.search("refund").first?.kind, .place)
        expect(!(try store.search("retry").isEmpty), "the next step is indexed too")
        expectEqual(try store.search("refund").first?.recordId, "/p/acme",
                    "a place navigates by its path, not by a thread")
    }

    // An ambient span nobody wrote on is not a memory. Indexing every app
    // switch would bury the handful of sentences somebody typed.
    TestKit.test("an app you merely opened is not a memory") {
        let store = try store()
        _ = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: Date(), endedAt: Date(), appName: "Calculator",
            target: "unremarkable"
        ))
        expect(try store.search("unremarkable").isEmpty, "nothing was written down here")
    }

    TestKit.suite("Keeping the index true")

    TestKit.test("editing a note replaces what was indexed rather than adding to it") {
        let store = try store()
        let event = try remember("the first thing I thought", into: store)
        _ = try store.annotate(activityId: event.id, note: "what I actually meant")

        expect(try store.search("first").isEmpty, "the old words are gone")
        expectEqual(try store.search("actually").count, 1, "and the new ones are there once")
    }

    // The place arrives on a separate write from the note, so a memory whose
    // project lands a moment later has to be reindexed or it stays findable
    // only by its words.
    TestKit.test("a place that arrives after the note still becomes searchable") {
        let store = try store()
        let event = try remember("come back to this", into: store)
        expect(try store.search("lateplace").isEmpty)

        try store.describeActivity(id: event.id, metadata: ["place": "lateplace"])
        expectEqual(try store.search("lateplace").count, 1)
    }

    TestKit.test("clearing a note removes it from the index") {
        let store = try store()
        let event = try remember("something forgettable", into: store)
        _ = try store.annotate(activityId: event.id, note: "   ")
        expect(try store.search("forgettable").isEmpty, "no longer a memory, no longer findable")
    }

    TestKit.suite("Deleting means deleting")

    TestKit.test("a deleted memory leaves nothing behind in the index") {
        let store = try store()
        let event = try remember("this should not survive", into: store)
        try store.deleteActivity(id: event.id)
        expect(try store.search("survive").isEmpty)
    }

    TestKit.test("deleting a day takes its memories out of the index") {
        let store = try store()
        let yesterday = Date().addingTimeInterval(-86_400)
        try remember("yesterday's thought", into: store, at: yesterday)
        try remember("today's thought", into: store)

        try store.deleteActivity(on: yesterday)
        expect(try store.search("yesterday").isEmpty, "gone")
        expectEqual(try store.search("today").count, 1, "and today untouched")
    }

    TestKit.test("deleting a project note takes it out of the index") {
        let store = try store()
        var note = ProjectNote(repositoryPath: "/p/acme", repositoryName: "acme")
        note.building = "the refund pipeline"
        try store.saveProjectNote(note)
        try store.deleteProjectNote(repositoryPath: "/p/acme")
        expect(try store.search("refund").isEmpty)
    }

    TestKit.suite("Ranking and empty results")

    // Titles are weighted eight times bodies, so the memory whose place is the
    // thing you typed should come above one that merely mentions it.
    TestKit.test("the place you searched for outranks a passing mention") {
        let store = try store()
        try remember("a passing mention of billing in the text", place: "unrelated", into: store)
        try remember("come back to this", place: "billing", into: store)

        let hits = try store.search("billing")
        expectEqual(hits.count, 2, "both matched")
        expectEqual(hits.first?.title, "billing", "the one it is about comes first")
    }

    TestKit.test("a search that matches nothing returns nothing, not everything") {
        let store = try store()
        try remember("waiting on the Stripe webhook docs", into: store)
        expect(try store.search("kangaroo").isEmpty)
    }

    TestKit.test("an empty or punctuation-only query is not a search") {
        let store = try store()
        try remember("something worth finding", into: store)
        expect(try store.search("").isEmpty)
        expect(try store.search("   ").isEmpty)
        expect(try store.search("!!!").isEmpty)
    }

    TestKit.test("a query that looks like FTS syntax does not throw") {
        let store = try store()
        try remember("something worth finding", into: store)
        for hostile in ["\"", "AND", "NEAR(", "a OR", "*", "col:value", "C++"] {
            _ = try store.search(hostile)
        }
    }

    TestKit.suite("Memories written before the index knew about them")

    // The half of the fix that matters to somebody with months of history:
    // indexing only new notes would have been indistinguishable from no fix.
    TestKit.test("notes already on disk become findable without being rewritten") {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-backfill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            let store = try Store(database: try FlowTraceDatabase(url: file))
            try remember("waiting on the Stripe webhook docs", place: "billing", into: store)
            var note = ProjectNote(repositoryPath: "/p/acme", repositoryName: "acme")
            note.building = "the refund pipeline"
            try store.saveProjectNote(note)

            // Wipe the index, as a database written before the fix would be.
            try store.database.writer.write { db in
                try db.execute(sql: "DELETE FROM searchIndex")
            }
            expect(try store.search("webhook").isEmpty, "the state the fix has to repair")
        }

        // What the migration does on a database that predates the fix.
        let reopened = try Store(database: try FlowTraceDatabase(url: file))
        try reopened.reindexMemories()
        expectEqual(try reopened.search("webhook").count, 1, "the memory came back")
        expectEqual(try reopened.search("refund").count, 1, "and so did the project note")
    }
}

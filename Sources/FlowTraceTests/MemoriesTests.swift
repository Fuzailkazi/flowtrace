import Foundation
import FlowTraceCore

/// The three read-only accessors the Memories and Memory Detail screens use.
func runMemoriesTests() {
    TestKit.suite("Memories — what you wrote, across days")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }

    func noted(_ app: String, note: String?, at minutes: Int, kind: ActivityKind = .app) -> ActivityEvent {
        ActivityEvent(
            kind: kind, startedAt: at(minutes), endedAt: at(minutes),
            appName: app, note: note, noteAt: note == nil ? nil : at(minutes)
        )
    }

    TestKit.test("notedActivity lists only rows with a note, newest first, across days") {
        let store = try store()
        try store.recordActivity(noted("Chrome", note: "pricing page", at: 0))
        try store.recordActivity(noted("VS Code", note: nil, at: 10))
        try store.recordActivity(noted("Figma", note: "", at: 20))
        try store.recordActivity(noted("Terminal", note: "check the HUD level", at: 60 * 24 * 3))
        let memories = try store.notedActivity()
        expectEqual(memories.count, 2, "only noted rows")
        expectEqual(memories.first?.appName, "Terminal", "newest first")
        expectEqual(memories.last?.appName, "Chrome")
    }

    TestKit.test("notedActivity honours its limit") {
        let store = try store()
        for i in 0..<5 { try store.recordActivity(noted("App \(i)", note: "n\(i)", at: i)) }
        expectEqual(try store.notedActivity(limit: 2).count, 2)
    }

    TestKit.test("activity(id:) returns the row, and nil once it is forgotten") {
        let store = try store()
        let saved = try store.recordActivity(noted("Chrome", note: "why", at: 0))
        expectEqual(try store.activity(id: saved.id)?.note, "why")
        try store.deleteActivity(id: saved.id)
        expect(try store.activity(id: saved.id) == nil, "gone after delete")
    }

    TestKit.test("activity(around:) returns neighbours inside the window, in order, noted or not") {
        let store = try store()
        try store.recordActivity(noted("Substack", note: nil, at: -4))
        try store.recordActivity(noted("Chrome", note: "the memory", at: 0))
        try store.recordActivity(noted("Notes", note: nil, at: 3))
        try store.recordActivity(noted("Terminal", note: nil, at: 8))
        try store.recordActivity(noted("Slack", note: nil, at: 120))
        let around = try store.activity(around: at(0), within: 45)
        expectEqual(around.map(\.appName), ["Substack", "Chrome", "Notes", "Terminal"])
    }
}

/// What FlowTrace reports it is holding on disk.
func runHoldingsSizeTests() {
    TestKit.suite("Holdings — the size on disk")

    // WAL mode means recent writes sit in a sidecar file. Measuring only the
    // main database reported 4 KB while a megabyte sat beside it.
    TestKit.test("the size counts the write-ahead log beside the database") {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-holdings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = directory.appendingPathComponent("flowtrace.sqlite")
        try Data(repeating: 0, count: 4_096).write(to: database)
        expectEqual(Store.storedBytes(at: database), 4_096, "database only")

        try Data(repeating: 0, count: 10_000).write(
            to: directory.appendingPathComponent("flowtrace.sqlite-wal")
        )
        try Data(repeating: 0, count: 1_000).write(
            to: directory.appendingPathComponent("flowtrace.sqlite-shm")
        )
        expectEqual(Store.storedBytes(at: database), 15_096, "database plus sidecars")
    }

    TestKit.test("a database that isn't there yet reports nothing rather than failing") {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-missing-\(UUID().uuidString).sqlite")
        expectEqual(Store.storedBytes(at: missing), 0)
    }
}

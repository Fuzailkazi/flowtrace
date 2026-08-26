import Foundation
import FlowTraceCore

func runActivityTests() {
    TestKit.suite("The day — coalescing")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }

    func event(
        _ app: String, target: String? = nil, at minutes: Int, kind: ActivityKind = .app
    ) -> ActivityEvent {
        ActivityEvent(
            kind: kind,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes) * 60),
            appName: app, target: target
        )
    }

    // Forty alt-tabs must not become forty lines. This is the single rule that
    // decides whether a day is readable.
    TestKit.test("staying in the same place keeps one span, not many") {
        let store = try store()
        for minute in 0..<10 {
            try store.beginActivity(event("VS Code", target: "flowtrace", at: minute))
        }
        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                    minimumSeconds: 0)
        expectEqual(day.count, 1, "spans")
        expectEqual(day.first?.appName, "VS Code")
    }

    TestKit.test("switching apps closes the previous span at the moment you left") {
        let store = try store()
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 30))

        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                     minimumSeconds: 0)
        expectEqual(day.count, 2, "spans")
        let first = try unwrap(day.first)
        expectNotNil(first.endedAt, "first span should be closed")
        expectEqual(first.duration, 1800, "30 minutes")
        expect(try unwrap(day.last).isOpen, "the current span stays open")
    }

    // Nipping to Slack and back is one sitting, not three.
    TestKit.test("returning within a few minutes resumes the span rather than splitting it") {
        let store = try store()
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Slack", at: 10))
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 12))

        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                     minimumSeconds: 0)
        let vsCode = day.filter { $0.appName == "VS Code" }
        expectEqual(vsCode.count, 1, "VS Code should appear once")
        expect(try unwrap(vsCode.first).isOpen, "and be the open span again")
    }

    TestKit.test("the same app looking at something different is a new line") {
        let store = try store()
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 0, kind: .browserTab))
        try store.beginActivity(event("Chrome", target: "stripe.com", at: 5, kind: .browserTab))

        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                     minimumSeconds: 0)
        expectEqual(day.count, 2, "different pages are different entries")
    }

    TestKit.suite("The day — reading and annotating")

    TestKit.test("a glance is not something you were doing") {
        let store = try store()
        try store.beginActivity(event("Finder", at: 0))
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 1))

        // Finder got 60 seconds; with a 5-minute floor it shouldn't be listed.
        let filtered = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                          minimumSeconds: 300)
        expect(!filtered.contains { $0.appName == "Finder" }, "brief glances are dropped")
    }

    // If you wrote about it, it mattered — regardless of how long it lasted.
    TestKit.test("anything you explained is kept however brief") {
        let store = try store()
        let brief = try store.beginActivity(event("Finder", at: 0))
        try store.beginActivity(event("VS Code", at: 1))
        _ = try store.annotate(activityId: brief.id, note: "grabbing the logo file")

        let filtered = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                          minimumSeconds: 300)
        expect(filtered.contains { $0.appName == "Finder" }, "an annotated glance is kept")
    }

    TestKit.test("unexplained is the count the header shows") {
        let store = try store()
        let a = try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 30))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        expectEqual(try store.activity(on: day, minimumSeconds: 0).filter(\.isUnexplained).count, 2)

        _ = try store.annotate(activityId: a.id, note: "rebuilding the capture layer")
        expectEqual(try store.activity(on: day, minimumSeconds: 0).filter(\.isUnexplained).count, 1)
    }

    TestKit.test("an empty note clears the reason rather than storing blankness") {
        let store = try store()
        let e = try store.beginActivity(event("VS Code", at: 0))
        _ = try store.annotate(activityId: e.id, note: "something")
        let cleared = try unwrap(try store.annotate(activityId: e.id, note: "   "))
        expectNil(cleared.note, "note")
        expect(cleared.isUnexplained)
    }

    // The delete control that makes ambient capture liveable.
    TestKit.test("forgetting a day removes it entirely") {
        let store = try store()
        try store.beginActivity(event("VS Code", at: 0))
        try store.beginActivity(event("Chrome", at: 30))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        expect(try store.activity(on: day, minimumSeconds: 0).count > 0)
        try store.deleteActivity(on: day)
        expectEqual(try store.activity(on: day, minimumSeconds: 0).count, 0, "after forgetting")
    }

    TestKit.test("durations read the way people say them") {
        var e = event("VS Code", at: 0)
        e.endedAt = e.startedAt.addingTimeInterval(3840)
        expectEqual(e.durationLabel, "1h 04m")
        e.endedAt = e.startedAt.addingTimeInterval(720)
        expectEqual(e.durationLabel, "12m")
        e.endedAt = e.startedAt.addingTimeInterval(20)
        expectEqual(e.durationLabel, "under a minute")
    }
}

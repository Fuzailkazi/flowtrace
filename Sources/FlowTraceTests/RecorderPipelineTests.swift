import Foundation
import FlowTraceCore

/// The recorder no longer writes spans on the main thread: the window-title
/// read, the browser's Apple Event and the database write all happen on one
/// serial queue. These cover the invariants that change rests on.
///
/// The recorder itself needs AppKit notifications and a run loop, so what is
/// tested here is the seam it sits on — the store, driven the way the recorder
/// now drives it.
func runRecorderPipelineTests() {
    TestKit.suite("Recording off the main thread")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }
    func event(_ app: String, target: String? = nil, at minutes: Int) -> ActivityEvent {
        ActivityEvent(
            kind: .app, startedAt: at(minutes), appName: app,
            bundleIdentifier: "com.example.\(app.lowercased())", target: target
        )
    }

    // The reason the queue is serial. Two app switches a moment apart used to be
    // two synchronous writes on the main thread and so could not interleave;
    // off the main thread they can, and interleaving would close the wrong span.
    TestKit.test("spans written off the main thread keep the order they happened in") {
        let store = try store()
        let queue = DispatchQueue(label: "test.recorder.order")
        let done = DispatchSemaphore(value: 0)

        for minute in [0, 5, 10] {
            queue.async {
                try? store.beginActivity(event("App \(minute)", at: minute))
            }
        }
        queue.async { done.signal() }
        done.wait()

        let day = try store.allActivity(on: base, minimumSeconds: 0)
        expectEqual(day.map(\.appName), ["App 0", "App 5", "App 10"], "written in order")
        expectEqual(day.filter(\.isOpen).count, 1, "only the last is still open")
        expectEqual(day.first?.endedAt, at(5), "the first closed when the second began")
    }

    // Enrichment can take seconds — a wedged browser can take much longer. A
    // close that arrives while one is in flight has to land behind it, or the
    // day ends on a span nothing ever closed.
    TestKit.test("a close queued behind a slow write still closes that span") {
        let store = try store()
        let queue = DispatchQueue(label: "test.recorder.close")
        let done = DispatchSemaphore(value: 0)

        queue.async {
            // Stands in for reading a window title and asking a browser for its tab.
            Thread.sleep(forTimeInterval: 0.05)
            try? store.beginActivity(event("Brave Browser", target: "a page", at: 0))
        }
        queue.async { try? store.endOpenActivity(at: at(3)) }
        queue.async { done.signal() }
        done.wait()

        let day = try store.allActivity(on: base, minimumSeconds: 0)
        expectEqual(day.count, 1)
        expectEqual(day.first?.endedAt, at(3), "closed at the moment the machine went quiet")
        expect(try store.openActivity() == nil, "nothing left open")
    }

    // Quitting closes the span directly rather than through the queue, because
    // the process may not live long enough to drain it. What must hold is that
    // the close uses the moment of the quit.
    TestKit.test("closing on quit ends the span at the moment of the quit") {
        let store = try store()
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))

        try store.endOpenActivity(at: at(42))

        let day = try store.allActivity(on: base, minimumSeconds: 0)
        expectEqual(day.count, 1)
        expectEqual(day.first?.endedAt, at(42))
        expect(try store.openActivity() == nil, "nothing left open after quitting")
    }

    // The guard that stops in-flight enrichment writing after a close: without
    // it, quitting would close a span and the queue would immediately open
    // another, leaving one open forever.
    TestKit.test("a span that arrives after the quit close leaves one open for the repair") {
        let store = try store()
        try store.beginActivity(event("VS Code", at: 0))
        try store.endOpenActivity(at: at(10))

        // What the dropped write would have done had it not been skipped.
        try store.beginActivity(event("Brave Browser", at: 11))
        expect(try store.openActivity() != nil, "it would have left a span open")

        // And why that is survivable even if it ever happens: the launch repair
        // closes it rather than leaving it to stretch across the night.
        let closed = try store.closeStaleOpenActivity(lastSeenAt: at(11), now: at(600))
        expectEqual(closed, 1)
        expect(try store.openActivity() == nil, "closed at the next launch")
    }

    TestKit.suite("A note is never lost")

    // The signal the capture panel uses to know its target vanished — Settings
    // can forget a day, or prune can remove the row, while the panel floats over
    // another app. A nil return is what makes it write the words down beside the
    // gap instead of reporting success over nothing.
    TestKit.test("annotating a row that has been forgotten returns nil rather than succeeding") {
        let store = try store()
        let span = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: at(0), endedAt: at(1), appName: "Brave Browser"
        ))
        try store.deleteActivity(id: span.id)

        expect(try store.annotate(activityId: span.id, note: "why I was here") == nil,
               "nil, so the caller knows to write the note somewhere else")
    }

    // The rescue path itself: the words land as an entry of their own.
    TestKit.test("a rescued note is kept as its own entry") {
        let store = try store()
        try store.recordActivity(ActivityEvent(
            kind: .browserTab, startedAt: at(0), endedAt: at(0),
            appName: "Brave Browser", target: "a page", url: "https://example.com",
            note: "checking whether the redirect is on their side", noteAt: at(0)
        ))

        let day = try store.activity(on: base, minimumSeconds: 0)
        expectEqual(day.count, 1)
        expectEqual(day.first?.note, "checking whether the redirect is on their side")
        expect(try store.openActivity() == nil, "a rescue is a point, not a span")
    }

    // Recording off means a capture is complete in itself. This is the failure
    // that made every note after the first overwrite the one before it.
    TestKit.test("with the recorder off nothing is left open for the next note to overwrite") {
        let store = try store()
        let now = at(0)
        for app in ["Brave Browser", "Terminal", "VS Code"] {
            let plan = CaptureTargeting.plan(
                open: try store.openActivity(),
                site: CaptureSite(appName: app, bundleIdentifier: "com.example.\(app)"),
                recording: false, now: now
            )
            guard case .recordPoint(var built) = plan else {
                TestKit.fail("expected a point with the recorder off, got \(plan)"); return
            }
            built.note = "why I was in \(app)"
            built.noteAt = now
            try store.recordActivity(built)
        }

        expect(try store.openActivity() == nil, "nothing open")
        let day = try store.activity(on: base, minimumSeconds: 0)
        expectEqual(day.count, 3, "three notes, none overwritten")
        expectEqual(Set(day.compactMap(\.note)).count, 3, "each kept its own words")
    }
}

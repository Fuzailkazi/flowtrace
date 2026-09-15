import Foundation
import FlowTraceCore

/// Noting why you left a place, from the place itself.
///
/// The flow reuses the one capture pipeline rather than adding a second, so
/// most of what is asserted here is that the existing pieces carry a place
/// through unchanged. The part that is new is which place they are given when
/// the key is pressed inside FlowTrace, and that is a `CaptureSite` question.
func runContextualCaptureTests(repositoryRoot: URL) {
    TestKit.suite("Where a note lands")

    // What the panel builds when the user presses the key over another app.
    func siteInApp(_ name: String, bundle: String? = nil) -> CaptureSite {
        CaptureSite(appName: name, bundleIdentifier: bundle, pageTitle: "some window")
    }

    // What it builds when the key is pressed while reading a place in FlowTrace.
    func siteOnPlace(_ name: String, root: String) -> CaptureSite {
        CaptureSite(
            appName: "FlowTrace", bundleIdentifier: "ai.flowtrace.FlowTrace",
            pageTitle: "some window", placeName: name, placeRoot: root, placeChecked: true
        )
    }

    // The bug the flow exists to avoid: a note about why the Stripe migration
    // was abandoned, filed against the app it was read in.
    TestKit.test("a note taken while reading a place is filed on that place") {
        let backfill = siteOnPlace("stripe-migration", root: "/p/stripe-migration").placeBackfill
        guard case .set(let name, let root) = backfill else {
            expect(false, "expected the place to be set, got \(backfill)")
            return
        }
        expectEqual(name, "stripe-migration")
        expectEqual(root, "/p/stripe-migration")
    }

    TestKit.test("a note taken anywhere else does not claim a place") {
        if case .set = siteInApp("Slack").placeBackfill {
            expect(false, "Slack is not a project")
        }
    }

    // A place read off the screen is known, not pending, so a fast Return must
    // not be mistaken for "the editor has not answered yet".
    TestKit.test("a place read off the screen is never treated as still arriving") {
        expect(siteOnPlace("acme", root: "/p/acme").placeChecked)
    }

    TestKit.suite("What the memory keeps")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }

    /// The write the panel performs, reduced to the three calls it makes.
    @discardableResult
    func capture(
        _ why: String, place: (name: String, root: String)?, into store: Store,
        at when: Date = Date()
    ) throws -> ActivityEvent {
        let target = try store.beginActivity(ActivityEvent(
            kind: .app, startedAt: when, appName: "FlowTrace"
        ))
        if let place {
            try store.describeActivity(
                id: target.id, metadata: ["place": place.name, "cwd": place.root]
            )
        }
        _ = try store.annotate(activityId: target.id, note: why)
        return target
    }

    // PLACE, WHY, WHEN — the three things the memory is supposed to retain.
    TestKit.test("place, why and when all survive the write") {
        let store = try store()
        let target = try capture(
            "Waiting on Stripe webhook docs.",
            place: (name: "stripe-migration", root: "/p/stripe-migration"),
            into: store
        )

        let saved = try unwrap(try store.activity(id: target.id))
        expectEqual(saved.note, "Waiting on Stripe webhook docs.", "WHY")
        expectEqual(saved.metadata["place"], "stripe-migration", "PLACE")
        expectEqual(saved.metadata["cwd"], "/p/stripe-migration", "the place's path")
        expect(saved.noteAt != nil, "WHEN")
    }

    TestKit.test("the place is written even though nobody typed it") {
        let store = try store()
        let target = try capture(
            "come back to the webhook retry", place: (name: "acme", root: "/p/acme"), into: store
        )
        let saved = try unwrap(try store.activity(id: target.id))
        // The user typed one sentence. Everything else was worked out.
        expectEqual(saved.metadata["place"], "acme")
        expect(saved.appName != nil)
        expect(saved.startedAt <= Date())
    }

    TestKit.suite("When it goes wrong")

    // An empty note is not a memory. The panel closes without writing one, so
    // nothing here should ever carry an empty string.
    TestKit.test("an empty note is not worth a row") {
        let text = "   \n  "
        expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               "the guard the panel applies before it writes anything")
    }

    // The invariant from the capture-correctness phase: a failed write must not
    // swallow the words.
    TestKit.test("annotating a row that is not there reports failure rather than losing the words") {
        let store = try store()
        let result = try store.annotate(activityId: "no-such-row", note: "words worth keeping")
        expect(result == nil, "the caller is told, and still holds the text")
    }

    // Pressing the key twice in the same place should not produce two memories
    // that disagree.
    // Pressing the key twice in the same place inside one span does not open a
    // second row — the recorder coalesces them. That is why the panel diverts a
    // second note rather than calling `annotate` again: at this level the write
    // simply replaces, and the words the user typed the first time would be
    // gone with nothing to show it happened.
    TestKit.test("two notes in one span land on one row, which is why the panel diverts") {
        let store = try store()
        let first = try capture("first thought", place: (name: "acme", root: "/p/acme"), into: store)
        let second = try capture("second thought", place: (name: "acme", root: "/p/acme"), into: store)

        expectEqual(second.id, first.id, "coalesced into the span already open")
        expectEqual(try unwrap(try store.activity(id: first.id)).note, "second thought",
                    "a bare annotate replaces, so the panel must not use one here")
    }

    // A note survives the process that wrote it. This is the whole promise.
    TestKit.test("a note written now is there on the next read") {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-relaunch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }

        let id: String
        do {
            let store = try Store(database: try FlowTraceDatabase(url: file))
            id = try capture(
                "Waiting on Stripe webhook docs.",
                place: (name: "stripe-migration", root: "/p/stripe-migration"), into: store
            ).id
        }
        // A completely separate Store over the same file, as a relaunch is.
        let reopened = try Store(database: try FlowTraceDatabase(url: file))
        let saved = try unwrap(try reopened.activity(id: id))
        expectEqual(saved.note, "Waiting on Stripe webhook docs.")
        expectEqual(saved.metadata["place"], "stripe-migration")
    }

    TestKit.suite("One shortcut, everywhere")

    // The requirement is structural, so the assertion is structural: there must
    // be exactly one place in the product that names a specific key. Everything
    // else reads the user's configured trigger, which is why changing it in
    // Settings changes every screen at once.
    //
    // A literal key combination appearing in a view is the failure this catches,
    // and it is the failure that actually happened — an earlier build shipped
    // one shortcut in the onboarding copy and a different one in Settings.
    TestKit.test("no screen spells out the capture shortcut") {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        // Assembled rather than written, so this file is not itself an example
        // of the thing it forbids.
        let forbidden = "\u{2325}" + "Space"
        var offenders: [String] = []

        guard let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) else {
            expect(false, "could not read \(sources.path)")
            return
        }

        for case let file as URL in walker where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            // The two files allowed to name the key: the one that defines the
            // default, and the one that turns a stored shortcut into letters.
            // And this file, which has to name it to look for it.
            guard !["HotKeyShortcut.swift", "CaptureTrigger.swift",
                    "ContextualCaptureTests.swift"].contains(name) else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (number, line) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                // Comments explain; they do not ship to the user.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(forbidden) else { continue }
                offenders.append("\(name):\(number + 1) \(code)")
            }
        }

        expect(offenders.isEmpty, "the key is spelled out here instead of read from the setting:\n"
               + offenders.joined(separator: "\n"))
    }
}

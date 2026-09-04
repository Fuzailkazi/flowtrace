# Capture Lands Where You Pressed the Key — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A sentence typed in Quick Capture lands on the place the key was pressed — not on whatever span the recorder happens to have open — and no note is ever silently lost or overwritten.

**Architecture:** A new pure `CaptureTargeting` type in `FlowTraceCore` decides, from the open span plus a snapshot of where the key was pressed, whether to annotate the open span, begin a new one, or record a standalone point; it also decides what may be pre-filled and what may be overwritten. `QuickCaptureView` becomes a thin caller: it waits (bounded) for the browser tab to resolve, re-fetches the open span, asks `CaptureTargeting`, and writes. Span lifecycle bugs are fixed where spans are owned — in `ActivityRecorder` (heartbeat, close-on-quit) and `Store` (close stale spans at launch).

**Tech Stack:** Swift 6 tools / language mode v5, SwiftUI (macOS 14+), Swift Package Manager, GRDB, custom `TestKit` harness (no XCTest).

---

## Before you start

Read the approved spec in full: `docs/superpowers/specs/2026-09-03-capture-lands-where-you-pressed-the-key-design.md`. It went through three review passes; every rule below traces to it. Read the audit item it implements (0.1) in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` for the failure history.

Commands:
- Build: `swift build` (from the worktree root)
- Test: `Scripts/test.sh` (runs everything in `Sources/FlowTraceTests/main.swift`; there is no per-test filter). Baseline before this plan: **136 passed**.

`FlowTraceTests` depends on `FlowTraceCore` only, so Tasks 1–2 are TDD with real tests; Tasks 3–6 touch `FlowTraceApp` and are verified by `swift build` plus the manual pass in Task 7.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FlowTraceCore/Capture/CaptureTargeting.swift` (new) | `CaptureSite`, `CapturePlan`, and the pure rules: `plan`, `prefill`, `mayOverwrite`. No I/O, no AppKit. |
| `Sources/FlowTraceTests/CaptureTargetingTests.swift` (new) | One test per rule row, plus `prefill`/`mayOverwrite`/point-shape cases. |
| `Sources/FlowTraceCore/Activity/ActivityStore.swift` (modify) | `closeStaleOpenActivity(lastSeenAt:now:)`. |
| `Sources/FlowTraceCore/Activity/ActivityRecorder.swift` (modify) | Heartbeat key + writes; close the span on app termination. |
| `Sources/FlowTraceApp/AppModel.swift` (modify) | Close stale spans synchronously at launch, before the recorder starts. |
| `Sources/FlowTraceApp/AppLifecycle.swift` (modify) | Correct the comment that claims it closes the span. |
| `Sources/FlowTraceApp/Capture/FrontmostSnapshot.swift` (modify) | `site` mapping; identity via `activeTab(of:)`, count separately. |
| `Sources/FlowTraceApp/Capture/QuickCaptureView.swift` (modify) | State, two-step enrichment, gated header duration, rewritten `save()`, in-panel error. |
| `Sources/FlowTraceTests/ActivityTests.swift` (modify) | Store-level tests for stale spans, points, coalescing and resume-keeps-note. |
| `Sources/FlowTraceTests/main.swift` (modify) | Register `runCaptureTargetingTests()`. |

---

## Task 1: `CaptureTargeting` — the pure rules

**Files:**
- Create: `Sources/FlowTraceCore/Capture/CaptureTargeting.swift`
- Create: `Sources/FlowTraceTests/CaptureTargetingTests.swift`
- Modify: `Sources/FlowTraceTests/main.swift`

- [ ] **Step 1: Write the failing tests**

Create `Sources/FlowTraceTests/CaptureTargetingTests.swift`:

```swift
import Foundation
import FlowTraceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)

private func site(
    app: String = "Safari", bundle: String? = "com.apple.Safari",
    title: String? = nil, url: String? = nil, tabs: Int = 0,
    isBrowser: Bool = true, denied: Bool = false
) -> CaptureSite {
    CaptureSite(
        appName: app, bundleIdentifier: bundle, pageTitle: title, url: url,
        openTabCount: tabs, isBrowser: isBrowser, automationDenied: denied
    )
}

private func span(
    bundle: String? = "com.apple.Safari", title: String? = "A", url: String? = "https://a.example",
    note: String? = nil
) -> ActivityEvent {
    ActivityEvent(
        kind: url == nil ? .app : .browserTab, startedAt: now.addingTimeInterval(-600),
        appName: "Safari", bundleIdentifier: bundle, target: title, url: url,
        note: note, noteAt: note == nil ? nil : now.addingTimeInterval(-500)
    )
}

func runCaptureTargetingTests() {
    TestKit.suite("CaptureTargeting — where the note goes")

    // Recording off is the default for every new install, and the old code left
    // an immortal span behind that every later capture overwrote.
    TestKit.test("recording off always records a standalone point") {
        let plan = CaptureTargeting.plan(
            open: span(note: "an older note"), site: site(url: "https://b.example"),
            recording: false, now: now
        )
        guard case .recordPoint(let event) = plan else {
            TestKit.fail("expected recordPoint, got \(plan)"); return
        }
        expectEqual(event.startedAt, now)
        expectEqual(event.endedAt, now)
        expectEqual(event.kind, .browserTab)
    }

    TestKit.test("a point from a non-browser site is an app event") {
        let plan = CaptureTargeting.plan(
            open: nil, site: site(app: "iTerm2", bundle: "com.googlecode.iterm2", isBrowser: false),
            recording: false, now: now
        )
        guard case .recordPoint(let event) = plan else {
            TestKit.fail("expected recordPoint, got \(plan)"); return
        }
        expectEqual(event.kind, .app)
        expectEqual(event.appName, "iTerm2")
    }

    TestKit.test("no open span begins one") {
        let plan = CaptureTargeting.plan(
            open: nil, site: site(title: "B", url: "https://b.example"), recording: true, now: now
        )
        guard case .beginSpan(let event) = plan else {
            TestKit.fail("expected beginSpan, got \(plan)"); return
        }
        expectEqual(event.url, "https://b.example")
        expectEqual(event.target, "B")
    }

    TestKit.test("a different app begins a span") {
        let plan = CaptureTargeting.plan(
            open: span(bundle: "com.microsoft.VSCode", title: "main.swift", url: nil),
            site: site(title: "B", url: "https://b.example"), recording: true, now: now
        )
        guard case .beginSpan = plan else { TestKit.fail("expected beginSpan, got \(plan)"); return }
    }

    // A nil bundle id on either side cannot be matched, so it is a different app.
    TestKit.test("a missing bundle identifier is never the same app") {
        let plan = CaptureTargeting.plan(
            open: span(bundle: nil), site: site(url: "https://a.example"), recording: true, now: now
        )
        guard case .beginSpan = plan else { TestKit.fail("expected beginSpan, got \(plan)"); return }
    }

    // The span opened before the tab could be read: fill it in rather than split it.
    TestKit.test("same app, span has no page yet, site does: annotate and back-fill") {
        let plan = CaptureTargeting.plan(
            open: span(title: "Safari", url: nil),
            site: site(title: "B", url: "https://b.example"), recording: true, now: now
        )
        guard case .annotateOpen(_, let url, let title) = plan else {
            TestKit.fail("expected annotateOpen, got \(plan)"); return
        }
        expectEqual(url, "https://b.example")
        expectEqual(title, "B")
    }

    // A terminal or editor: the snapshot knows only the app, so the recorder's
    // span (which has the window title) is the better answer.
    TestKit.test("same app and the site knows no page: annotate the open span") {
        let plan = CaptureTargeting.plan(
            open: span(bundle: "com.microsoft.VSCode", title: "main.swift", url: nil),
            site: site(app: "Code", bundle: "com.microsoft.VSCode", isBrowser: false),
            recording: true, now: now
        )
        guard case .annotateOpen(let event, let url, let title) = plan else {
            TestKit.fail("expected annotateOpen, got \(plan)"); return
        }
        expectEqual(event.target, "main.swift")
        expectNil(url)
        expectNil(title)
    }

    TestKit.test("same page annotates the open span") {
        let plan = CaptureTargeting.plan(
            open: span(url: "https://a.example"), site: site(url: "https://a.example"),
            recording: true, now: now
        )
        guard case .annotateOpen = plan else {
            TestKit.fail("expected annotateOpen, got \(plan)"); return
        }
    }

    // The headline failure: you changed tabs less than 30 seconds ago, so the
    // recorder's span is the page you left.
    TestKit.test("a different page in the same browser begins a span, and pre-fills nothing") {
        let open = span(url: "https://a.example", note: "why I opened A")
        let there = site(title: "B", url: "https://b.example")
        guard case .beginSpan(let event) = CaptureTargeting.plan(
            open: open, site: there, recording: true, now: now
        ) else { TestKit.fail("expected beginSpan"); return }
        expectEqual(event.url, "https://b.example")
        expectNil(CaptureTargeting.prefill(open: open, site: there, recording: true))
    }

    TestKit.test("more than one tab open is recorded on the event") {
        guard case .beginSpan(let event) = CaptureTargeting.plan(
            open: nil, site: site(url: "https://b.example", tabs: 11), recording: true, now: now
        ) else { TestKit.fail("expected beginSpan"); return }
        expectEqual(event.metadata["tabsOpen"], "11")
    }

    TestKit.suite("CaptureTargeting — what the field may show")

    // While the tab is still being read the open span may be the previous tab,
    // and its words are the wrong words.
    TestKit.test("a browser whose tab has not been read yet pre-fills nothing") {
        expectNil(CaptureTargeting.prefill(
            open: span(note: "the previous tab's reason"), site: site(url: nil), recording: true
        ))
    }

    // Denied is different from not-yet-read: the url will never arrive.
    TestKit.test("a browser that refused access pre-fills the open span's note") {
        expectEqual(CaptureTargeting.prefill(
            open: span(title: "Safari", url: nil, note: "reading the docs"),
            site: site(url: nil, denied: true), recording: true
        ), "reading the docs")
    }

    TestKit.test("a non-browser app pre-fills the open span's note") {
        expectEqual(CaptureTargeting.prefill(
            open: span(bundle: "com.microsoft.VSCode", title: "main.swift", url: nil, note: "fixing the save path"),
            site: site(app: "Code", bundle: "com.microsoft.VSCode", isBrowser: false),
            recording: true
        ), "fixing the save path")
    }

    TestKit.test("recording off pre-fills nothing") {
        expectNil(CaptureTargeting.prefill(
            open: span(note: "an older note"), site: site(url: "https://a.example"), recording: false
        ))
    }

    TestKit.test("a different app pre-fills nothing") {
        expectNil(CaptureTargeting.prefill(
            open: span(note: "an older note"),
            site: site(app: "Code", bundle: "com.microsoft.VSCode", isBrowser: false),
            recording: true
        ))
    }

    TestKit.suite("CaptureTargeting — what may be overwritten")

    TestKit.test("nothing there is safe to write") {
        expect(CaptureTargeting.mayOverwrite(existing: nil, shown: nil))
        expect(CaptureTargeting.mayOverwrite(existing: "   ", shown: nil))
    }

    TestKit.test("what the field showed you is yours to replace") {
        expect(CaptureTargeting.mayOverwrite(existing: "x", shown: "x"))
    }

    // The whole point: words you never saw are never destroyed.
    TestKit.test("words the panel never showed are never overwritten") {
        expect(!CaptureTargeting.mayOverwrite(existing: "x", shown: nil))
        expect(!CaptureTargeting.mayOverwrite(existing: "x", shown: "y"))
    }
}
```

- [ ] **Step 2: Register it and watch the build fail**

In `Sources/FlowTraceTests/main.swift`, add after `runCaptureSuggesterTests()`:

```swift
runCaptureTargetingTests()
```

Run: `Scripts/test.sh`
Expected: build FAILS — no `CaptureSite`, `CapturePlan`, `CaptureTargeting`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlowTraceCore/Capture/CaptureTargeting.swift`:

```swift
import Foundation

/// Where the key was pressed, as the capture panel knows it.
///
/// AppKit-free on purpose: the rules that decide where a note lands are the
/// part worth testing, and they must be testable without a window server.
public struct CaptureSite: Sendable, Equatable {
    public var appName: String
    public var bundleIdentifier: String?
    public var pageTitle: String?
    public var url: String?
    public var openTabCount: Int
    /// A browser FlowTrace knows how to read. With `url == nil` this means the
    /// tab has not been read *yet*, or could not be — not "this is not a page".
    public var isBrowser: Bool
    /// macOS refused the read, so `url` is never going to arrive.
    public var automationDenied: Bool

    public init(
        appName: String, bundleIdentifier: String? = nil, pageTitle: String? = nil,
        url: String? = nil, openTabCount: Int = 0, isBrowser: Bool = false,
        automationDenied: Bool = false
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.pageTitle = pageTitle
        self.url = url
        self.openTabCount = openTabCount
        self.isBrowser = isBrowser
        self.automationDenied = automationDenied
    }
}

/// What to do with the sentence the user just typed.
///
/// Deliberately not `Equatable`: a built event carries a fresh id, so tests
/// pattern-match the case and compare the fields they care about.
public enum CapturePlan: Sendable {
    /// Write onto the span the recorder already has open. The back-fill fields
    /// are set when the span knows the app but not the page, and the site does.
    case annotateOpen(ActivityEvent, backfillURL: String?, backfillTitle: String?)
    /// Close whatever is open and begin a span for this site, via
    /// `Store.beginActivity` — whose coalescing and resume rules still apply.
    case beginSpan(ActivityEvent)
    /// Recording is off: one closed, zero-length event. A point, not a span,
    /// so nothing is left open for the next capture to overwrite.
    case recordPoint(ActivityEvent)
}

/// Decides where a captured sentence goes.
///
/// The panel snapshots where you were *before* it appears, so the snapshot —
/// not the recorder's open span — is the truth about where the key was
/// pressed. The exception is when the snapshot knows less than the span does:
/// a terminal has no window title in the snapshot, and a browser tab takes an
/// AppleScript round trip to read. In those cases the open span is the better
/// answer, and these rules say exactly when.
public enum CaptureTargeting {
    public static func plan(
        open: ActivityEvent?, site: CaptureSite, recording: Bool, now: Date
    ) -> CapturePlan {
        // With no recorder there is no span to extend, and anything left open
        // stays open forever — so a capture is a point, complete in itself.
        guard recording else { return .recordPoint(event(for: site, at: now, closed: true)) }

        guard let open, isSameApp(open, site) else {
            return .beginSpan(event(for: site, at: now, closed: false))
        }

        if open.url == nil, let url = site.url {
            return .annotateOpen(open, backfillURL: url, backfillTitle: site.pageTitle)
        }
        // The snapshot cannot say more than "same app" — trust the span, which
        // has the window title or the tab the recorder managed to read.
        guard let there = site.url else { return .annotateOpen(open, backfillURL: nil, backfillTitle: nil) }
        guard open.url == there else { return .beginSpan(event(for: site, at: now, closed: false)) }
        return .annotateOpen(open, backfillURL: nil, backfillTitle: nil)
    }

    /// The note to pre-fill the field with, if any: only the open span's own
    /// note, and only when the plan is to annotate that span.
    ///
    /// Case selection does not depend on `now` — it only stamps a built event —
    /// so it is defaulted here.
    public static func prefill(
        open: ActivityEvent?, site: CaptureSite, recording: Bool, now: Date = Date()
    ) -> String? {
        // Mid-read, the open span may still be the tab you just left.
        if site.isBrowser, site.url == nil, !site.automationDenied { return nil }
        guard case .annotateOpen(let event, _, _) = plan(
            open: open, site: site, recording: recording, now: now
        ) else { return nil }
        guard let note = event.note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty
        else { return nil }
        return note
    }

    /// Whether writing over `existing` is safe: there is nothing there, or it
    /// is exactly what the field showed — the user saw those words and chose to
    /// replace them. Anything else is words they never saw.
    public static func mayOverwrite(existing: String?, shown: String?) -> Bool {
        let existing = (existing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return true }
        return existing == (shown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: -

    private static func isSameApp(_ event: ActivityEvent, _ site: CaptureSite) -> Bool {
        guard let a = event.bundleIdentifier, let b = site.bundleIdentifier else { return false }
        return a == b
    }

    private static func event(for site: CaptureSite, at now: Date, closed: Bool) -> ActivityEvent {
        ActivityEvent(
            kind: site.url != nil ? .browserTab : .app,
            startedAt: now,
            endedAt: closed ? now : nil,
            appName: site.appName,
            bundleIdentifier: site.bundleIdentifier,
            target: site.pageTitle,
            url: site.url,
            metadata: site.openTabCount > 1 ? ["tabsOpen": String(site.openTabCount)] : [:]
        )
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `Scripts/test.sh`
Expected: the two new suites pass (18 tests), total **154 passed**.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceCore/Capture/CaptureTargeting.swift \
        Sources/FlowTraceTests/CaptureTargetingTests.swift \
        Sources/FlowTraceTests/main.swift
git commit -m "Decide where a captured note lands, in one testable place"
```

---

## Task 2: Stale spans are closed, and points are first-class

**Files:**
- Modify: `Sources/FlowTraceCore/Activity/ActivityStore.swift`
- Modify: `Sources/FlowTraceTests/ActivityTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runActivityTests()` in `Sources/FlowTraceTests/ActivityTests.swift` (match the file's existing store-setup helper — it builds a `Store` on an in-memory or temp database; reuse it exactly rather than inventing a new one):

```swift
    TestKit.suite("Spans left open")

    // A crash, a force-quit, or the old capture bug leaves `endedAt` nil. Left
    // alone it becomes a span stretching to now — or worse, gets resumed.
    TestKit.test("a span left open is closed a minute after the app was last seen") {
        let store = try makeStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, appName: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
        let lastSeen = started.addingTimeInterval(8 * 3600)
        let closed = try store.closeStaleOpenActivity(
            lastSeenAt: lastSeen, now: lastSeen.addingTimeInterval(12 * 3600)
        )
        expectEqual(closed, 1)
        expectNil(try store.openActivity())
        let event = try unwrap(try store.allActivity(on: started).first)
        expectEqual(event.endedAt, lastSeen.addingTimeInterval(60))
    }

    TestKit.test("with no heartbeat a stale span is a minute long, not a lie") {
        let store = try makeStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, appName: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
        _ = try store.closeStaleOpenActivity(
            lastSeenAt: nil, now: started.addingTimeInterval(30 * 3600)
        )
        let event = try unwrap(try store.allActivity(on: started).first)
        expectEqual(event.endedAt, started.addingTimeInterval(60))
    }

    TestKit.test("a span never ends before it started") {
        let store = try makeStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, appName: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
        _ = try store.closeStaleOpenActivity(
            lastSeenAt: started.addingTimeInterval(-300), now: started.addingTimeInterval(3600)
        )
        let event = try unwrap(try store.allActivity(on: started).first)
        expectEqual(event.endedAt, started)
    }

    TestKit.test("closed spans are left alone") {
        let store = try makeStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let ended = started.addingTimeInterval(600)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, endedAt: ended, appName: "Code",
            bundleIdentifier: "com.microsoft.VSCode"
        ))
        expectEqual(try store.closeStaleOpenActivity(lastSeenAt: Date(), now: Date()), 0)
        let event = try unwrap(try store.allActivity(on: started).first)
        expectEqual(event.endedAt, ended)
    }

    TestKit.suite("Notes with the recorder off")

    // Two captures from two apps must be two rows. The old code overwrote the
    // first with the second, forever, because it annotated the open span.
    TestKit.test("two captures in two apps are two notes, and nothing stays open") {
        let store = try makeStore()
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        for (app, bundle, text) in [
            ("Safari", "com.apple.Safari", "checking the redirect"),
            ("Code", "com.microsoft.VSCode", "fixing the save path"),
        ] {
            let at = app == "Safari" ? first : first.addingTimeInterval(120)
            try store.recordActivity(ActivityEvent(
                kind: .app, startedAt: at, endedAt: at, appName: app,
                bundleIdentifier: bundle, note: text, noteAt: at
            ))
        }
        let written = try store.activity(on: first)
        expectEqual(written.count, 2)
        expectNil(try store.openActivity())
    }

    TestKit.suite("Coming back to a page you wrote about")

    // `save()` depends on this: the resume branch hands back the *old* span,
    // note included, so the caller must not blindly annotate it.
    TestKit.test("returning to a noted page resumes it with the note intact") {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        func tab(_ url: String, _ title: String, at: Date) -> ActivityEvent {
            ActivityEvent(
                kind: .browserTab, startedAt: at, appName: "Safari",
                bundleIdentifier: "com.apple.Safari", target: title, url: url
            )
        }
        let a = try store.beginActivity(tab("https://a.example", "A", at: start))
        _ = try store.annotate(activityId: a.id, note: "why I opened A")
        _ = try store.beginActivity(tab("https://b.example", "B", at: start.addingTimeInterval(60)))
        let resumed = try store.beginActivity(tab("https://a.example", "A", at: start.addingTimeInterval(120)))
        expectEqual(resumed.id, a.id)
        expectEqual(resumed.note, "why I opened A")
    }

    TestKit.test("a new page closes the span that was open") {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let a = try store.beginActivity(ActivityEvent(
            kind: .browserTab, startedAt: start, appName: "Safari",
            bundleIdentifier: "com.apple.Safari", target: "A", url: "https://a.example"
        ))
        let switched = start.addingTimeInterval(45)
        _ = try store.beginActivity(ActivityEvent(
            kind: .browserTab, startedAt: switched, appName: "Safari",
            bundleIdentifier: "com.apple.Safari", target: "B", url: "https://b.example"
        ))
        let closed = try unwrap(try store.allActivity(on: start).first { $0.id == a.id })
        expectEqual(closed.endedAt, switched)
    }
```

If `ActivityTests.swift` has no `makeStore()` helper, use whatever it already does to get a `Store` (look at the top of the file) and keep the tests consistent with it.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `Scripts/test.sh`
Expected: build FAILS — `closeStaleOpenActivity` does not exist. (The other new tests should pass once it compiles; they assert existing store behaviour the rest of this plan depends on.)

- [ ] **Step 3: Write the implementation**

In `Sources/FlowTraceCore/Activity/ActivityStore.swift`, add after `endOpenActivity` (currently ends line 72):

```swift
    /// Closes spans nothing ever closed: a crash, a force-quit, or a capture
    /// taken while the recorder was off.
    ///
    /// The end is a minute after the app was last seen alive, not now — a
    /// laptop shut at 18:00 and opened at 09:00 did not spend the night in
    /// VS Code. Without a heartbeat the span becomes a minute long, which is
    /// the smallest honest answer.
    ///
    /// Runs at launch, before the recorder can extend or resume one of these.
    /// It closes *every* open row, which is safe because only the recorder and
    /// the capture panel ever write one — imports and tab notes write closed
    /// rows — and that invariant is why a future importer must not write
    /// `endedAt == nil`.
    @discardableResult
    public func closeStaleOpenActivity(lastSeenAt: Date?, now: Date = Date()) throws -> Int {
        try database.writer.write { db in
            let open = try ActivityEvent
                .filter(ActivityEvent.Columns.endedAt == nil)
                .fetchAll(db)
            for var event in open {
                let assumed = (lastSeenAt ?? event.startedAt).addingTimeInterval(60)
                event.endedAt = max(event.startedAt, min(now, assumed))
                try event.update(db)
            }
            return open.count
        }
    }
```

- [ ] **Step 4: Run the tests**

Run: `Scripts/test.sh`
Expected: all green; total **161 passed** (154 + 7).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceCore/Activity/ActivityStore.swift Sources/FlowTraceTests/ActivityTests.swift
git commit -m "Close spans that nothing else will ever close"
```

---

## Task 3: The recorder owns the span's end

**Files:**
- Modify: `Sources/FlowTraceCore/Activity/ActivityRecorder.swift`
- Modify: `Sources/FlowTraceApp/AppModel.swift`
- Modify: `Sources/FlowTraceApp/AppLifecycle.swift`

No automated coverage — `FlowTraceTests` cannot import `FlowTraceApp`, and the recorder needs a window server. Verify with `swift build` and Task 7.

- [ ] **Step 1: Heartbeat and the terminate observer**

In `ActivityRecorder.swift`:

1. Add the key next to the other stored properties (near `isRunning`, ~line 41):

```swift
    /// When the recorder last knew the machine was alive. Read at launch to
    /// close a span a crash left open, since a crash writes nothing.
    public static let lastSeenAtKey = "flowtrace.recorder.lastSeenAt"
```

2. Register the terminate observer **in `init`**, not in `start()` — closing the open span on quit should happen whether or not recording is on, and `stop()` only removes workspace-centre observers, so a `start()`-time registration would leak on every toggle:

```swift
    public init(store: Store) {
        self.store = store
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
            using: { _ in MainActor.assumeIsolated { self.closeSpan() } }
        )
        #endif
    }
```

3. Write the heartbeat as the **first statement** of `captureFrontmost()` — before its `isRunning`/`isIdle` guards, so an idle machine still records that the app was alive (line 115-116 today):

```swift
    public func captureFrontmost() {
        UserDefaults.standard.set(Date(), forKey: Self.lastSeenAtKey)
        guard isRunning, !isIdle else { return }
```

and as the first statement of `checkIdle()` (line 196):

```swift
    private func checkIdle() {
        UserDefaults.standard.set(Date(), forKey: Self.lastSeenAtKey)
        guard isRunning else { return }
```

- [ ] **Step 2: Close stale spans at launch, before the recorder starts**

In `AppModel.swift`, `startRecordingIfEnabled()` (line 132). The close must be **synchronous and first**: `recorder.start()` calls `captureFrontmost()` → `beginActivity`, which would close a stale span at `now` or resume it outright.

```swift
    func startRecordingIfEnabled() {
        // Before anything can extend or resume them: close spans that a crash,
        // a quit, or a capture taken with the recorder off left open.
        let lastSeenAt = UserDefaults.standard.object(
            forKey: ActivityRecorder.lastSeenAtKey
        ) as? Date
        if let closed = try? store.closeStaleOpenActivity(lastSeenAt: lastSeenAt), closed > 0 {
            Diagnostics.log("activity: closed \(closed) span(s) left open")
        }

        if isRecording { recorder.start() }
        importSessions()
        …
    }
```

- [ ] **Step 3: Correct the comment that lies**

In `AppLifecycle.swift`, `applicationWillTerminate` (line 32-36) claims it closes the span but only logs. Replace the doc comment:

```swift
    /// The recorder closes its own open span on termination — see
    /// `ActivityRecorder.init`. This is here for the log line only.
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.log("app terminating")
    }
```

- [ ] **Step 4: Build and run the suite**

Run: `swift build` — expected: clean.
Run: `Scripts/test.sh` — expected: still **161 passed** (no Core behaviour changed).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceCore/Activity/ActivityRecorder.swift \
        Sources/FlowTraceApp/AppModel.swift Sources/FlowTraceApp/AppLifecycle.swift
git commit -m "Know when the machine was last alive, and close the span on quit"
```

---

## Task 4: The snapshot knows the tab it is on

**Files:**
- Modify: `Sources/FlowTraceApp/Capture/FrontmostSnapshot.swift`

- [ ] **Step 1: Split identity from the count, and expose a `site`**

Today `resolvingBrowserTab()` (line 60-77) enumerates every tab and picks `tabs.first(where: \.isActive) ?? tabs.first` — so when the active-tab index read fails it silently targets the *first* tab, and a note filed from that lands on the wrong page. Identity now comes from `activeTab(of:)`, the same call the recorder uses, and the enumeration is used only for the count.

Add to `FrontmostSnapshot`:

```swift
    /// Set when the browser is one we can read but the tab has not been read
    /// yet — distinct from `automationDenied`, where it never will be.
    var tabUnread: Bool { isBrowser && url == nil && !automationDenied }

    /// The rules in `FlowTraceCore` decide where a note lands; this is what
    /// they are given.
    var site: CaptureSite {
        CaptureSite(
            appName: appName, bundleIdentifier: bundleIdentifier, pageTitle: pageTitle,
            url: url, openTabCount: openTabCount, isBrowser: isBrowser,
            automationDenied: automationDenied
        )
    }
```

Replace `resolvingBrowserTab()` with two functions — identity first, because `activeTab` reads one tab while `tabsInFrontWindow` walks the whole window and is the half that can take a second:

```swift
    /// Reads the tab you are on. One tab, one round trip — this is what the
    /// note's destination depends on, so nothing slower is allowed to hold it up.
    func resolvingActiveTab() -> FrontmostSnapshot {
        guard let browser = matchedBrowser else { return self }

        var resolved = self
        do {
            if let tab = try BrowserTabReader().activeTab(of: browser) {
                resolved.pageTitle = tab.pageTitle
                resolved.url = tab.url
            }
        } catch let error as BrowserReadError {
            if case .permissionDenied = error { resolved.automationDenied = true }
        } catch {
            // Not running, or the window went away — nothing to report.
        }
        return resolved
    }

    /// How many tabs are open beside it — the difference between "you were on
    /// this page" and "you were on this page with eleven others". Enumerates
    /// the window, so it runs after the tab is already known.
    func resolvingTabCount() -> FrontmostSnapshot {
        guard let browser = matchedBrowser, !automationDenied else { return self }
        var resolved = self
        if let tabs = try? BrowserTabReader().tabsInFrontWindow(of: browser) {
            resolved.openTabCount = tabs.count
        }
        return resolved
    }
```

Leave `resolvingBrowserTab()` deleted — `QuickCaptureView` is its only caller and Task 5 rewrites that call.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: FAILS in `QuickCaptureView.swift` — `resolvingBrowserTab` is gone. That is the next task; do not fix it here. Confirm the only errors are that call site.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlowTraceApp/Capture/FrontmostSnapshot.swift
git commit -m "Read the tab you are on, not the first tab in the window"
```

(Committing a non-building tree is deliberate here: Tasks 4 and 5 are one change split for reviewability, and the next task restores the build. If your workflow forbids it, do Tasks 4 and 5 as one commit.)

---

## Task 5: The panel asks where the note goes

**Files:**
- Modify: `Sources/FlowTraceApp/Capture/QuickCaptureView.swift`

- [ ] **Step 1: New state**

In the `@State` block (lines 15-21), add:

```swift
    @State private var plan: CapturePlan?
    /// What the field was pre-filled with, if anything. A note may only be
    /// overwritten if the user actually saw it.
    @State private var shownNote: String?
    @State private var enrichmentFinished = false
    @State private var saving = false
    @State private var saveError: String?
```

- [ ] **Step 2: Two-step enrichment, and a plan from the start**

Replace `load()` (lines 287-307):

```swift
    private func load() {
        focused = true
        current = try? model.store.openActivity()
        leadingUp = (try? model.store.activityLeadingUp(to: Date())) ?? []
        refreshPlan()
        recomputeSuggestion(tabNote: nil)

        // The tab is read in two steps. Which tab you are on decides where the
        // note lands, so it is published the moment it is known; how many other
        // tabs are open is decoration, and walking the window for it is the
        // slow half.
        let snapshot = self.snapshot
        Task.detached(priority: .userInitiated) {
            let identified = snapshot.resolvingActiveTab()
            await MainActor.run {
                if identified != snapshot { resolved = identified }
                refreshPlan()
                if note.isEmpty, let prefill = CaptureTargeting.prefill(
                    open: current, site: resolved.site, recording: model.recorder.isRunning
                ) {
                    note = prefill
                    shownNote = prefill
                }
                if let url = identified.url {
                    recomputeSuggestion(tabNote: (try? model.store.noteForTab(url: url)) ?? nil)
                }
                // Everything the note's destination depends on is now known.
                enrichmentFinished = true
            }

            let counted = identified.resolvingTabCount()
            await MainActor.run { if counted != identified { resolved = counted } }
        }
    }

    private func refreshPlan() {
        plan = CaptureTargeting.plan(
            open: current, site: resolved.site,
            recording: model.recorder.isRunning, now: Date()
        )
    }
```

Note what is deliberate: `note` is no longer seeded from `current?.note` (line 291 today). That line is the recording-off overwrite bug — it put an unrelated row's words in the field. The pre-fill now comes only from `CaptureTargeting.prefill`, which returns nil while a browser tab is unread, and `enrichmentFinished` is set outside the `identified != snapshot` check so a non-browser app — where `resolvingActiveTab` returns `self` — never waits.

- [ ] **Step 3: The header stops showing someone else's duration**

In `header` (lines 82-86), `current.durationLabel` is shown whenever the span is open, which after a tab switch is the previous tab's duration under the new tab's title. Gate it:

```swift
                if let current, current.isOpen, isAnnotatingOpenSpan {
                    Text("·").foregroundStyle(Journal.ruleFirm)
                    Text(current.durationLabel)
                }
```

and add next to `refreshPlan()`:

```swift
    private var isAnnotatingOpenSpan: Bool {
        if case .annotateOpen = plan { return true }
        return false
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean — the Task 4 break is repaired and `save()` still compiles (it is rewritten next).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceApp/Capture/QuickCaptureView.swift
git commit -m "Ask where the note goes, and stop pre-filling an unrelated note"
```

---

## Task 6: Save it where the key was pressed, or don't lose it

**Files:**
- Modify: `Sources/FlowTraceApp/Capture/QuickCaptureView.swift`

- [ ] **Step 1: Rewrite `save()`**

Replace `save()` (lines 309-351). It stays synchronous — `.onSubmit` and the Escape button both take `() -> Void` — sets `saving` **before** spawning the task (a `Task` body runs on a later main-actor hop, so setting it inside would let a second Return through), and clears it with `defer`:

```swift
    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { onFinish(); return }
        guard !saving else { return }
        saving = true
        saveError = nil

        Task { @MainActor in
            defer { saving = false }
            await waitForTab()

            do {
                // The load-time span can be seconds stale, and which tab you are
                // on may only just have arrived.
                current = try model.store.openActivity()
                refreshPlan()
                try write(text)

                model.refresh()
                saved = true
                try? await Task.sleep(for: .milliseconds(600))
                onFinish()
            } catch {
                Diagnostics.log("capture save failed: \(error)")
                saveError = "Couldn't write that down. Your words are still here — press Return to try again."
            }
        }
    }

    /// Waits for the tab to be identified, but not for long.
    ///
    /// A one-word note and a fast Return can beat the AppleScript round trip,
    /// and saving before the tab is known files the note on the page you left.
    /// A polled flag rather than awaiting the task: the read is a synchronous
    /// Apple Event whose own timeout is two minutes, so there is nothing to
    /// cancel and nothing that would return early.
    private func waitForTab() async {
        guard !enrichmentFinished else { return }
        let deadline = ContinuousClock.now + .seconds(1.5)
        while !enrichmentFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func write(_ text: String) throws {
        let now = Date()
        switch plan ?? .recordPoint(ActivityEvent(
            kind: .app, startedAt: now, endedAt: now, appName: resolved.appName
        )) {
        case .recordPoint(var event):
            event.note = text
            event.noteAt = now
            try model.store.recordActivity(event)

        case .annotateOpen(let open, let url, let title):
            if url != nil || title != nil {
                try model.store.describeActivity(id: open.id, target: title, url: url)
            }
            try annotate(open, with: text, at: now)

        case .beginSpan(let event):
            // Coalescing may hand back a span you noted earlier and have not
            // seen in this panel — `annotate` would replace those words.
            let target = try model.store.beginActivity(event)
            try annotate(target, with: text, at: now)
        }
    }

    private func annotate(_ target: ActivityEvent, with text: String, at now: Date) throws {
        // Already said, nothing to do — accepting a suggestion sourced from this
        // very page arrives here.
        if target.note == text { return }

        guard CaptureTargeting.mayOverwrite(existing: target.note, shown: shownNote) else {
            // Words the panel never showed. Keep both: yours goes down beside
            // them rather than over them.
            var point = ActivityEvent(
                kind: resolved.url != nil ? .browserTab : .app,
                startedAt: now, endedAt: now,
                appName: resolved.appName, bundleIdentifier: resolved.bundleIdentifier,
                target: resolved.pageTitle, url: resolved.url,
                note: text, noteAt: now
            )
            try model.store.recordActivity(point)
            _ = point
            return
        }
        _ = try model.store.annotate(activityId: target.id, note: text)
    }
```

- [ ] **Step 2: Show the failure in the panel, and ignore Escape mid-save**

The old `catch` dismissed the panel and put the error in `model.toast`, which only renders inside `MainWindow` — the window the README tells you to keep closed. So the sentence vanished with no confirmation and no explanation.

In `editor` (lines 122-158), add the notice after `suggestionRow` (line 140):

```swift
            if let saveError {
                HStack(spacing: Journal.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Journal.amber)
                    Text(saveError)
                        .font(.observed(11.5))
                        .foregroundStyle(Journal.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: 6))
            }
```

Clear it as soon as the text changes — add to the `TextField` chain:

```swift
                .onChange(of: note) { _, _ in saveError = nil }
```

And make Escape a no-op while a write is in flight, so a dismissal cannot race a save that is already committed (line 153-157):

```swift
        .background {
            Button("") { if !saving { onFinish() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean. If the compiler objects to `switch plan ?? …` over a non-`Equatable` enum, bind first: `guard let plan else { return }` after `refreshPlan()` (it always assigns), and switch on that.

- [ ] **Step 4: Run the suite**

Run: `Scripts/test.sh`
Expected: **161 passed**, unchanged — no Core behaviour was touched.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceApp/Capture/QuickCaptureView.swift
git commit -m "Write the note where the key was pressed, and never lose one silently"
```

---

## Task 7: Manual verification

No UI test harness exists, and every failure this plan fixes is a timing or permission interaction. Run `Scripts/dev.sh` (rebuilds, kills the running instance, relaunches). **Back up the real database first**: `cp ~/Library/Application\ Support/FlowTrace/flowtrace.sqlite ~/Desktop/flowtrace-backup.sqlite`.

- [ ] **Step 1: Recording off — two captures are two notes**

Settings → recording **off**. Capture in Safari ("checking the redirect"), then in Terminal ("why I'm in here"). Today shows **two** noted rows; the second capture's field was **empty** (not pre-filled with the first) and showed the Smart Capture row. Settings → What FlowTrace knows → no span is left open (or check the raw view).

- [ ] **Step 2: Recording on — the fast tab switch**

Recording **on**. Open a new tab and press the capture key within 10 seconds. The note lands on the **new** tab: Today's row carries its title, and pressing the key again on that tab pre-fills what you wrote. The previous tab's note is untouched.

- [ ] **Step 3: Recording on — a terminal or editor**

Accessibility granted, recording on. Capture in VS Code or iTerm2: one row with the **window title**, not a bare title-less row, and not a second row beside the recorder's.

- [ ] **Step 4: Automation denied**

With a browser whose Automation FlowTrace has been refused: capture over a tab. The panel shows the Allow… notice, and the note lands on the recorder's open span for that browser.

- [ ] **Step 5: Coming back to a page you wrote about**

Note tab A. Switch to B, wait for a tick, return to A, and capture a **different** sentence. Today shows **both** — A's original note and your new one as a separate entry. Nothing was overwritten.

- [ ] **Step 6: Typing before the tab resolves**

On a browser window with many tabs: press the key and type one word and Return as fast as you can, before the header changes from the browser's name to the page title. The note still lands on the right tab (the save waited). Repeat on a tab whose span already carries a note: your word appears as a **separate** entry rather than replacing words you never saw.

- [ ] **Step 7: Quit with a span open**

With recording on and a span open, quit FlowTrace (⌘Q) and relaunch. `~/Library/Application Support/FlowTrace/debug.log` shows either the terminate close or `closed N span(s) left open`. A capture the next morning is a fresh row dated today, not an entry filed under yesterday.

- [ ] **Step 8: A failed write keeps your words**

Make the write fail (`chmod 444` the sqlite file, or move it aside mid-session) and capture. The panel **stays open**, the sentence is still in the field, an amber line explains, Escape does nothing while the save is in flight, and after restoring permissions Return saves it. Double-Return writes once.

- [ ] **Step 9: Report**

If all eight behave as described, this sub-project is done. If anything diverges, say exactly which step and what happened before changing code — every one of these is a timing interaction, and guessing costs more than reproducing.

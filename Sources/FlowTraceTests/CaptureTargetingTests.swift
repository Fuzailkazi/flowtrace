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

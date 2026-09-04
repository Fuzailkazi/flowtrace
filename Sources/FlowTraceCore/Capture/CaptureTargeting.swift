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

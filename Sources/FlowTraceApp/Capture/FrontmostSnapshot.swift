import AppKit
import ApplicationServices
import FlowTraceCore

/// Where you were the instant you pressed the key.
///
/// Captured *before* the panel appears, because opening it changes the answer —
/// by the time the user is typing, the frontmost app is FlowTrace.
struct FrontmostSnapshot: Equatable {
    var appName: String
    var bundleIdentifier: String?
    var pageTitle: String?
    var url: String?
    /// The focused window's title, read synchronously via Accessibility at
    /// key-press time. This is what makes the panel open *with* context —
    /// "XYZ video - YouTube" or "flowtrace — Code" — instead of a bare "Brave"
    /// that fills in a beat later once AppleScript returns. Nil when the
    /// permission isn't granted; never prompts.
    var windowTitle: String?

    /// How many tabs are open in that window — the difference between "you were
    /// on this page" and "you were on this page with eleven others".
    var openTabCount: Int = 0
    /// The browser was recognised but macOS wouldn't let us ask it anything.
    var automationDenied = false

    /// The project the editor has in front, once it has said. Arrives a beat
    /// after the panel draws — see the place task in `QuickCaptureView.load()`,
    /// which waits for the write our own activation triggers.
    var place: Place?
    /// Whether that task has finished, whatever it found. It lives here beside
    /// `place` rather than in view state because `site` is built from this
    /// snapshot and `site` is what the rules read: a nil `place` alone cannot
    /// tell "the editor gave no answer" from "we have not asked yet", and only
    /// the first of those may clear a place off a row.
    var placeChecked = false

    /// The app is a browser we know how to talk to, whether or not we managed to.
    var isBrowser: Bool {
        url != nil || automationDenied || matchedBrowser != nil
    }

    var matchedBrowser: SupportedBrowser? {
        guard let bundleIdentifier else { return nil }
        return SupportedBrowser.all.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// One line describing where the user is, for the top of the panel.
    var summary: String {
        if let pageTitle, !pageTitle.isEmpty { return pageTitle }
        if let windowTitle, !windowTitle.isEmpty { return windowTitle }
        if let url { return url }
        // The project an editor has in front, in the slot a page title occupies
        // for a browser: `flowtrace` rather than `Code`.
        if let place { return place.name }
        return appName
    }

    var detail: String? {
        if let url, let host = URL(string: url)?.host() {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        // A statement about where the answer came from, not a claim about
        // presence — the editor said which window is in front, nothing more.
        if url == nil, let place { return "\(place.editor)'s current window" }
        return nil
    }

    static func capture() -> FrontmostSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier
        let windowTitle = focusedWindowTitle(of: app)
        return FrontmostSnapshot(
            appName: app?.localizedName ?? "Unknown app",
            bundleIdentifier: bundleId,
            // Instant context: the window title is already the YouTube video
            // name or the editor file. The async tab read refines it with URL
            // a beat later; until then this is what the panel shows and where
            // the note lands.
            pageTitle: windowTitle,
            windowTitle: windowTitle
        )
    }

    /// Synchronous window-title read at key-press time. Pull, never watch:
    /// returns nil when Accessibility isn't granted and never prompts.
    private static func focusedWindowTitle(of app: NSRunningApplication?) -> String? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef
        ) == .success, let title = titleRef as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The rules in `FlowTraceCore` decide where a note lands; this is what
    /// they are given.
    var site: CaptureSite {
        CaptureSite(
            appName: appName, bundleIdentifier: bundleIdentifier, pageTitle: pageTitle,
            url: url, openTabCount: openTabCount, isBrowser: isBrowser,
            automationDenied: automationDenied,
            placeName: place?.name, placeRoot: place?.root,
            // Whether the app is one we could have asked at all. Without it a
            // capture with no place could not be told apart from a capture that
            // was never entitled to one, and every browser note would clear the
            // place an editor capture put on the shared open span.
            isEditor: EditorFamily.matching(bundleIdentifier: bundleIdentifier) != nil,
            placeChecked: placeChecked
        )
    }

    /// Reads the tab you are on. One tab, one round trip — this is what the
    /// note's destination depends on, so nothing slower is allowed to hold it up.
    ///
    /// A denied Automation permission is recorded rather than swallowed. It used
    /// to fall through to a bare app name, so a browser FlowTrace had never been
    /// granted access to looked identical to one with no tabs — and there was
    /// nothing to tell the user what was wrong or how to fix it.
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
}

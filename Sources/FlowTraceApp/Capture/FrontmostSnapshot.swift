import AppKit
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

    /// How many tabs are open in that window — the difference between "you were
    /// on this page" and "you were on this page with eleven others".
    var openTabCount: Int = 0
    /// The browser was recognised but macOS wouldn't let us ask it anything.
    var automationDenied = false

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
        if let url { return url }
        return appName
    }

    var detail: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    static func capture() -> FrontmostSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        return FrontmostSnapshot(
            appName: app?.localizedName ?? "Unknown app",
            bundleIdentifier: app?.bundleIdentifier
        )
    }

    /// Reads the active tab when the app you were in is a browser we can talk to.
    ///
    /// Runs after the snapshot so the panel can appear immediately; the tab
    /// details fill in a moment later rather than delaying the window.
    /// Reads the active tab, and how many others are open beside it.
    ///
    /// A denied Automation permission is recorded rather than swallowed. It used
    /// to fall through to a bare app name, so a browser FlowTrace had never been
    /// granted access to looked identical to one with no tabs — and there was
    /// nothing to tell the user what was wrong or how to fix it.
    func resolvingBrowserTab() -> FrontmostSnapshot {
        guard let browser = matchedBrowser else { return self }

        var resolved = self
        let reader = BrowserTabReader()
        do {
            let tabs = try reader.tabsInFrontWindow(of: browser)
            let active = tabs.first(where: \.isActive) ?? tabs.first
            resolved.pageTitle = active?.pageTitle
            resolved.url = active?.url
            resolved.openTabCount = tabs.count
        } catch let error as BrowserReadError {
            if case .permissionDenied = error { resolved.automationDenied = true }
        } catch {
            // Not running, or the window went away — nothing to report.
        }
        return resolved
    }
}

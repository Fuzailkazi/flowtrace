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

    /// The rules in `FlowTraceCore` decide where a note lands; this is what
    /// they are given.
    var site: CaptureSite {
        CaptureSite(
            appName: appName, bundleIdentifier: bundleIdentifier, pageTitle: pageTitle,
            url: url, openTabCount: openTabCount, isBrowser: isBrowser,
            automationDenied: automationDenied
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

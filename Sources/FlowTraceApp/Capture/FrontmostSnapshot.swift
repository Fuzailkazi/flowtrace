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

    var isBrowser: Bool { url != nil }

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
    func resolvingBrowserTab() -> FrontmostSnapshot {
        guard let bundleIdentifier,
              let browser = SupportedBrowser.all.first(where: { $0.bundleIdentifier == bundleIdentifier }),
              let tab = try? BrowserTabReader().activeTab(of: browser)
        else { return self }

        var resolved = self
        resolved.pageTitle = tab.pageTitle
        resolved.url = tab.url
        return resolved
    }
}

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A browser FlowTrace can read tabs from.
public struct SupportedBrowser: Hashable, Sendable, Identifiable {
    public var name: String
    public var bundleIdentifier: String

    /// Safari's scripting dictionary names the title property differently from
    /// the Chromium family.
    var titleProperty: String

    public var id: String { bundleIdentifier }

    public static let all: [SupportedBrowser] = [
        SupportedBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", titleProperty: "title"),
        SupportedBrowser(name: "Brave Browser", bundleIdentifier: "com.brave.Browser", titleProperty: "title"),
        SupportedBrowser(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", titleProperty: "title"),
        SupportedBrowser(name: "Arc", bundleIdentifier: "company.thebrowser.Browser", titleProperty: "title"),
        SupportedBrowser(name: "Dia", bundleIdentifier: "company.thebrowser.dia", titleProperty: "title"),
        SupportedBrowser(name: "Opera", bundleIdentifier: "com.operasoftware.Opera", titleProperty: "title"),
        SupportedBrowser(name: "Opera GX", bundleIdentifier: "com.operasoftware.OperaGX", titleProperty: "title"),
        SupportedBrowser(name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", titleProperty: "title"),
        SupportedBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", titleProperty: "name"),
    ]
}

/// A tab as read from a browser, before the user has decided anything about it.
public struct CapturedTab: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var pageTitle: String
    public var url: String
    public var browser: String
    public var windowTitle: String?
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        pageTitle: String,
        url: String,
        browser: String,
        windowTitle: String? = nil,
        isActive: Bool = false
    ) {
        self.id = id
        self.pageTitle = pageTitle
        self.url = url
        self.browser = browser
        self.windowTitle = windowTitle
        self.isActive = isActive
    }

    /// Host only, for the compact line under a page title.
    public var host: String {
        URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
    }

    public func asContext(note: String = "") -> BrowserContext {
        BrowserContext(
            browser: browser,
            windowTitle: windowTitle,
            pageTitle: pageTitle,
            url: url,
            note: note
        )
    }
}

public enum BrowserReadError: LocalizedError {
    case notRunning(String)
    case permissionDenied(String)
    case scriptFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .notRunning(let name):
            "\(name) isn't running."
        case .permissionDenied(let name):
            "macOS hasn't granted FlowTrace permission to read tabs from \(name)."
        case .scriptFailed(let name, let detail):
            "Couldn't read tabs from \(name): \(detail)"
        }
    }

    /// Permission is the one failure with a concrete fix, so it gets a concrete
    /// instruction rather than a generic error.
    public var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            "Open System Settings → Privacy & Security → Automation and enable FlowTrace."
        case .notRunning:
            "Open it and try again, or capture from a different browser."
        case .scriptFailed:
            nil
        }
    }
}

/// Reads open tabs from a browser using AppleScript.
///
/// Only the tab title and URL are read — never page contents, cookies, form
/// values or history. Nothing is captured until the user picks it from the
/// capture sheet, and a browser that isn't already running is never launched.
public struct BrowserTabReader: Sendable {
    public init() {}

    /// Browsers that are installed *and* currently running. Asking a browser
    /// that isn't running would launch it, which is not something a capture
    /// shortcut should ever do.
    public func availableBrowsers() -> [SupportedBrowser] {
        #if canImport(AppKit)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return SupportedBrowser.all.filter { running.contains($0.bundleIdentifier) }
        #else
        return []
        #endif
    }

    public func installedBrowsers() -> [SupportedBrowser] {
        #if canImport(AppKit)
        return SupportedBrowser.all.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
        #else
        return []
        #endif
    }

    /// Every tab in the browser's front window.
    public func tabsInFrontWindow(of browser: SupportedBrowser) throws -> [CapturedTab] {
        try read(browser: browser, activeOnly: false)
    }

    /// Just the tab the user is looking at.
    public func activeTab(of browser: SupportedBrowser) throws -> CapturedTab? {
        try read(browser: browser, activeOnly: true).first
    }

    // MARK: - AppleScript

    // Titles and URLs can contain anything, so the script joins fields with
    // control characters that cannot appear in either.
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    private func read(browser: SupportedBrowser, activeOnly: Bool) throws -> [CapturedTab] {
        #if canImport(AppKit)
        guard availableBrowsers().contains(browser) else {
            throw BrowserReadError.notRunning(browser.name)
        }

        let script = self.script(for: browser, activeOnly: activeOnly)
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw BrowserReadError.scriptFailed(browser.name, "could not compile")
        }
        let output = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            // -1743 is the Automation permission refusal; -600 means it stopped
            // running between the check above and the script.
            if code == -1743 { throw BrowserReadError.permissionDenied(browser.name) }
            if code == -600 { throw BrowserReadError.notRunning(browser.name) }
            throw BrowserReadError.scriptFailed(browser.name, message)
        }

        return parse(output.stringValue ?? "", browser: browser.name)
        #else
        throw BrowserReadError.notRunning(browser.name)
        #endif
    }

    public func script(for browser: SupportedBrowser, activeOnly: Bool) -> String {
        let title = browser.titleProperty
        let isSafari = browser.bundleIdentifier == "com.apple.Safari"
        let activeTabExpression = isSafari
            ? "current tab of w"
            : "active tab of w"
        let windowName = isSafari ? "name of w" : "title of active tab of w"

        let collect = activeOnly
            ? """
              set t to \(activeTabExpression)
              set out to out & (\(title) of t) & fs & (URL of t) & fs & "1" & rs
              """
            : """
              set activeIndex to 0
              try
                  set activeIndex to \(isSafari ? "index of current tab of w" : "active tab index of w")
              end try
              set i to 0
              repeat with t in tabs of w
                  set i to i + 1
                  if i is activeIndex then
                      set flag to "1"
                  else
                      set flag to "0"
                  end if
                  set out to out & (\(title) of t) & fs & (URL of t) & fs & flag & rs
              end repeat
              """

        return """
        set fs to (ASCII character 31)
        set rs to (ASCII character 30)
        set out to ""
        tell application id "\(browser.bundleIdentifier)"
            if (count of windows) is 0 then return ""
            set w to front window
            set winName to ""
            try
                set winName to (\(windowName)) as text
            end try
            \(collect)
            return winName & rs & rs & out
        end tell
        """
    }

    public func parse(_ raw: String, browser: String) -> [CapturedTab] {
        guard !raw.isEmpty else { return [] }
        let blocks = raw.components(separatedBy: Self.recordSeparator + Self.recordSeparator)
        let windowTitle = blocks.count > 1 ? blocks[0] : nil
        let body = blocks.count > 1 ? blocks[1...].joined(separator: Self.recordSeparator + Self.recordSeparator) : raw

        return body
            .components(separatedBy: Self.recordSeparator)
            .compactMap { record in
                let fields = record.components(separatedBy: Self.fieldSeparator)
                guard fields.count >= 2 else { return nil }
                let url = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty, url != "missing value" else { return nil }
                return CapturedTab(
                    pageTitle: fields[0].isEmpty ? url : fields[0],
                    url: url,
                    browser: browser,
                    windowTitle: (windowTitle?.isEmpty ?? true) ? nil : windowTitle,
                    isActive: fields.count > 2 && fields[2].hasPrefix("1")
                )
            }
    }
}

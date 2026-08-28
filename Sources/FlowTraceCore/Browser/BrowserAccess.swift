import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Whether FlowTrace is allowed to ask a given browser what it has open.
///
/// macOS grants Automation per *pair* of apps, and only ever prompts once: if the
/// prompt was dismissed or denied, the app is refused forever after with no
/// further prompt and no explanation. Waiting for that failure to surface during
/// a capture is how a browser ends up showing its own name instead of the page.
public enum BrowserAccess {
    public enum Status: String, Sendable {
        /// Asked and allowed.
        case connected
        /// Never asked. Connecting will show the macOS prompt.
        case notAsked
        /// Asked and refused. macOS will not prompt again — this one has to be
        /// changed in System Settings.
        case denied
        /// Installed but not currently open, so there is nothing to ask.
        case notRunning
    }

    public struct BrowserState: Identifiable, Sendable {
        public var browser: SupportedBrowser
        public var status: Status
        public var id: String { browser.id }

        public var explanation: String {
            switch status {
            case .connected: "FlowTrace can see which tab you're on."
            case .notAsked: "Connect to let FlowTrace read the current tab."
            case .denied: "Refused earlier — macOS won't ask again, so this one needs System Settings."
            case .notRunning: "Open it to connect."
            }
        }
    }

    /// Checks each installed browser, prompting for none of them.
    ///
    /// A read is attempted only against browsers already running, because asking
    /// a closed app tells you nothing and would launch it.
    public static func survey() -> [BrowserState] {
        #if canImport(AppKit)
        let reader = BrowserTabReader()
        let running = Set(reader.availableBrowsers().map(\.bundleIdentifier))

        return reader.installedBrowsers().map { browser in
            guard running.contains(browser.bundleIdentifier) else {
                return BrowserState(browser: browser, status: .notRunning)
            }
            return BrowserState(browser: browser, status: probe(browser))
        }
        #else
        return []
        #endif
    }

    /// Attempts one read. If FlowTrace has never asked, this is what makes macOS
    /// show its prompt — which is the entire point of a Connect button.
    @discardableResult
    public static func connect(_ browser: SupportedBrowser) -> Status {
        probe(browser)
    }

    private static func probe(_ browser: SupportedBrowser) -> Status {
        do {
            _ = try BrowserTabReader().activeTab(of: browser)
            return .connected
        } catch let error as BrowserReadError {
            switch error {
            case .permissionDenied: return .denied
            case .notRunning: return .notRunning
            case .scriptFailed: return .connected  // it answered; the window was odd
            }
        } catch {
            return .denied
        }
    }
}

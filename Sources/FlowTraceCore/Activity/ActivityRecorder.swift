import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

/// Watches what you're doing and writes it down as spans.
///
/// Three layers, each optional and each degrading cleanly to the one below:
///
///   1. **Which app is frontmost.** A plain `NSWorkspace` notification — no
///      permission of any kind, and enough on its own for a readable day.
///   2. **The window title.** Needs Accessibility. Read on demand when focus
///      changes rather than by a standing observer: nothing is watched
///      continuously, and nothing is stored that the user did not end up seeing.
///   3. **The browser tab.** Needs Automation, and only for browsers.
///
/// Nothing is captured while the screen is locked or the machine is idle, and
/// FlowTrace never records itself.
@MainActor
public final class ActivityRecorder {
    private let store: Store
    private var observers: [Any] = []
    private var idleTimer: Timer?

    /// Apps whose activity is never interesting: FlowTrace itself, and the
    /// system surfaces that flicker in front for a moment.
    private static let ignoredBundleIdentifiers: Set<String> = [
        "ai.flowtrace.FlowTrace",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
    ]

    /// Stop recording after this long without input — you walked away, and a
    /// four-hour "span" in Slack because the laptop was open is a lie.
    private let idleThreshold: TimeInterval = 3 * 60

    public private(set) var isRunning = false

    /// When the recorder last knew the machine was alive. Read at launch to
    /// close a span a crash left open, since a crash writes nothing.
    public static let lastSeenAtKey = "flowtrace.recorder.lastSeenAt"

    /// Browsers FlowTrace has met but is not allowed to ask about tabs.
    public private(set) var browsersNeedingPermission: Set<String> = []

    public var captureWindowTitles = true
    public var captureBrowserTabs = true

    public init(store: Store) {
        self.store = store
        #if canImport(AppKit)
        // Every other stored property has a default, so `self` is fully formed
        // by this line and may be captured. Weakly: the notification centre
        // would otherwise own the recorder for the life of the process, and this
        // token is never removed — quitting is the only thing it fires on.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
            using: { [weak self] _ in MainActor.assumeIsolated { self?.closeSpan() } }
        )
        #endif
    }

    // MARK: - Lifecycle

    public func start() {
        #if canImport(AppKit)
        guard !isRunning else { return }
        isRunning = true

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] _ in
            self?.captureFrontmost()
        }
        // Walking away, sleeping, or locking all end the span — otherwise the
        // last app of the evening appears to have been used all night.
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { [weak self] _ in self?.closeSpan() }
        }
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { [weak self] _ in self?.captureFrontmost() }
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }

        captureFrontmost()
        Diagnostics.log("activity: recording started")
        #endif
    }

    public func stop() {
        #if canImport(AppKit)
        guard isRunning else { return }
        isRunning = false
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        idleTimer?.invalidate()
        idleTimer = nil
        closeSpan()
        Diagnostics.log("activity: recording stopped")
        #endif
    }

    #if canImport(AppKit)
    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ handler: @escaping (Notification) -> Void
    ) {
        observers.append(center.addObserver(
            forName: name, object: nil, queue: .main,
            using: { notification in MainActor.assumeIsolated { handler(notification) } }
        ))
    }

    // MARK: - Capture

    /// Records whatever is in front right now, enriched as far as permissions allow.
    public func captureFrontmost() {
        UserDefaults.standard.set(Date(), forKey: Self.lastSeenAtKey)
        guard isRunning, !isIdle else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard let bundleId = app.bundleIdentifier,
              !Self.ignoredBundleIdentifiers.contains(bundleId) else { return }

        let name = app.localizedName ?? bundleId
        var event = ActivityEvent(
            kind: .app, startedAt: Date(), appName: name, bundleIdentifier: bundleId
        )

        // Layer 2: the window title, read once, right now.
        if captureWindowTitles, let title = focusedWindowTitle(of: app.processIdentifier) {
            event.target = title
        }

        // Layer 3: for a browser, the tab is a better answer than the window title.
        //
        // Automation is granted per pair of apps, so being allowed to ask Chrome
        // says nothing about Brave. A refusal used to fall through to a bare app
        // name, making an unpermitted browser indistinguishable from one with
        // nothing open; it is recorded now so Settings can offer the fix.
        if captureBrowserTabs,
           let browser = SupportedBrowser.all.first(where: { $0.bundleIdentifier == bundleId }) {
            do {
                let tab = try BrowserTabReader().activeTab(of: browser)
                if let tab {
                    event.kind = .browserTab
                    event.target = tab.pageTitle
                    event.url = tab.url
                    browsersNeedingPermission.remove(browser.name)
                }
            } catch let error as BrowserReadError {
                if case .permissionDenied = error {
                    browsersNeedingPermission.insert(browser.name)
                }
            } catch {
                // Not running, or no window — nothing to report.
            }
        }

        try? store.beginActivity(event)
    }

    /// The title of the app's focused window, via Accessibility.
    ///
    /// Pull mode by design: asked for at the moment focus changes, never watched.
    /// If the permission isn't granted this returns nil and the timeline simply
    /// shows the app without a subtitle.
    private func focusedWindowTitle(of pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let element = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }

        var titleRef: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(
            windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef
        ) == .success, let title = titleRef as? String else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Idleness

    private var isIdle: Bool {
        let since = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .init(rawValue: ~0)!
        )
        return since >= idleThreshold
    }

    private func checkIdle() {
        UserDefaults.standard.set(Date(), forKey: Self.lastSeenAtKey)
        guard isRunning else { return }
        if isIdle {
            closeSpan()
        } else {
            // Coalescing means this is free when nothing changed, and it catches
            // a tab switch inside a browser that never fires an app notification.
            captureFrontmost()
        }
    }

    private func closeSpan() {
        try? store.endOpenActivity()
    }
    #endif
}

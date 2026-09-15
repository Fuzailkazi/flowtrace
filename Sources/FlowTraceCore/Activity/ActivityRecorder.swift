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

    /// Everything that touches the database or another application runs here,
    /// in the order it happened. Serial on purpose: spans are a sequence, and
    /// two of them racing would close the wrong one.
    private let work = DispatchQueue(label: "ai.flowtrace.recorder", qos: .utility)

    /// Set when the recorder is stopping or the app is quitting, so work already
    /// on the queue drops its write rather than reopening a closed span. Guarded
    /// by a lock because it is set on the main thread and read on `work`.
    private let stopLock = NSLock()
    private nonisolated(unsafe) var _isStopping = false

    private nonisolated var isStopping: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return _isStopping
    }

    private nonisolated func markStopping() {
        stopLock.lock(); _isStopping = true; stopLock.unlock()
    }

    private nonisolated func clearStopping() {
        stopLock.lock(); _isStopping = false; stopLock.unlock()
    }

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
            using: { [weak self] _ in MainActor.assumeIsolated { self?.closeSpanNow() } }
        )
        #endif
    }

    // MARK: - Lifecycle

    public func start() {
        #if canImport(AppKit)
        guard !isRunning else { return }
        isRunning = true
        clearStopping()

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
        closeSpanNow()
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
    ///
    /// Only the questions that must be asked on the main thread are asked here:
    /// which app is frontmost, and when. Reading the window title, asking a
    /// browser for its tab, and writing the span all happen on `work` — the
    /// tab read is a synchronous Apple Event with a two-minute timeout, and a
    /// busy browser used to stall the main thread, which is exactly when the
    /// capture panel is trying to appear.
    public func captureFrontmost() {
        UserDefaults.standard.set(Date(), forKey: Self.lastSeenAtKey)
        guard isRunning, !isIdle else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard let bundleId = app.bundleIdentifier,
              !Self.ignoredBundleIdentifiers.contains(bundleId) else { return }

        // Stamped now, not when the write lands: the span began the moment you
        // switched, however long the browser takes to answer.
        let event = ActivityEvent(
            kind: .app, startedAt: Date(),
            appName: app.localizedName ?? bundleId, bundleIdentifier: bundleId
        )
        let pid = app.processIdentifier
        let wantsTitle = captureWindowTitles
        let wantsTabs = captureBrowserTabs
        let store = self.store

        // One serial queue, so spans are written in the order they happened.
        // Two app switches a moment apart must not race each other into the
        // database and close the wrong one.
        work.async { [weak self] in
            var event = event
            if wantsTitle, let title = Self.focusedWindowTitle(of: pid) {
                event.target = title
            }

            // Automation is granted per pair of apps, so being allowed to ask
            // Chrome says nothing about Brave. A refusal used to fall through to
            // a bare app name, making an unpermitted browser indistinguishable
            // from one with nothing open; it is recorded so Settings can offer
            // the fix.
            var denied: String?
            var allowed: String?
            if wantsTabs,
               let browser = SupportedBrowser.all.first(where: { $0.bundleIdentifier == bundleId }),
               // Asked without asking the user. A browser that has never been
               // connected is skipped rather than prompted: the recorder runs
               // in the background, and a dialog raised from there arrives with
               // no explanation of what asked for it.
               BrowserAccess.status(for: browser) == .connected {
                do {
                    if let tab = try BrowserTabReader().activeTab(of: browser) {
                        event.kind = .browserTab
                        event.target = tab.pageTitle
                        event.url = tab.url
                        allowed = browser.name
                    }
                } catch let error as BrowserReadError {
                    if case .permissionDenied = error { denied = browser.name }
                } catch {
                    // Not running, or no window — nothing to report.
                }
            }

            // Recording was switched off, or the app is quitting, while this was
            // being enriched. Opening a span now would leave one behind after
            // the close that has already happened.
            guard self?.isStopping != true else { return }

            do {
                try store.beginActivity(event)
            } catch {
                Diagnostics.log("activity: writing a span failed: \(error)")
            }

            if denied != nil || allowed != nil {
                Task { @MainActor in
                    if let denied { self?.browsersNeedingPermission.insert(denied) }
                    if let allowed { self?.browsersNeedingPermission.remove(allowed) }
                }
            }
        }
    }

    /// Waits for any span still being written, without blocking the caller's
    /// thread. The capture panel awaits this before deciding where a note goes:
    /// the recorder's write is no longer synchronous, so without it a note typed
    /// immediately after switching apps could be planned against the span the
    /// user just left.
    public func settled() async {
        await withCheckedContinuation { continuation in
            work.async { continuation.resume() }
        }
    }

    /// The title of the app's focused window, via Accessibility.
    ///
    /// Pull mode by design: asked for at the moment focus changes, never watched.
    /// If the permission isn't granted this returns nil and the timeline simply
    /// shows the app without a subtitle. `nonisolated` because it is called from
    /// `work`; the Accessibility API is safe to call off the main thread and
    /// blocks, which is the reason it is not called on it.
    private nonisolated static func focusedWindowTitle(of pid: pid_t) -> String? {
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

    /// Closes the open span for sleep, lock, or stepping away.
    ///
    /// Queued rather than written here, so it lands *after* any span still
    /// being enriched — closing first and writing second would leave the day
    /// ending on a span nothing ever closed.
    private func closeSpan() {
        let store = self.store
        let at = Date()
        work.async {
            do {
                try store.endOpenActivity(at: at)
            } catch {
                Diagnostics.log("activity: closing the open span failed: \(error)")
            }
        }
    }

    /// Closes the open span for quitting, or for recording being switched off.
    ///
    /// Written directly rather than queued: at termination the process may not
    /// live long enough to drain the queue, and waiting for it would mean
    /// waiting on an Apple Event to a browser that may be wedged. `isStopping`
    /// makes any in-flight enrichment drop its write instead, so nothing can
    /// open a span after this closes one.
    private func closeSpanNow() {
        markStopping()
        do {
            try store.endOpenActivity(at: Date())
        } catch {
            Diagnostics.log("activity: closing the open span on quit failed: \(error)")
        }
    }
    #endif
}

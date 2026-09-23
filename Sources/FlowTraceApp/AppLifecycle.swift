import AppKit
import SwiftUI
import Observation
import ServiceManagement
import FlowTraceCore

/// Keeps FlowTrace alive and reachable.
///
/// A global capture shortcut is only alive while the app is, and SwiftUI's
/// default is to terminate a macOS app when its last window closes. That made the
/// shortcut useless in practice: the log showed the trigger being registered on
/// every launch and never once firing, because the app had been closed hours
/// earlier and nothing was listening.
///
/// So: FlowTrace is a menu-bar resident (LSUIElement) with no dock icon and no
/// ⌘-Tab entry. Closing the window hides it, quitting is explicit via the menu
/// bar, and the quick-capture panel appears without bringing any window forward.
final class AppLifecycle: NSObject, NSApplicationDelegate {
    /// The model, handed over by `FlowTraceApp.init` before AppKit finishes
    /// launching. A static because the delegate is built by SwiftUI's adaptor,
    /// which gives no opportunity to pass anything in.
    @MainActor static var model: AppModel?

    /// The live delegate instance.
    ///
    /// `NSApp.delegate` is **not** this object. SwiftUI's
    /// `NSApplicationDelegateAdaptor` installs its own `AppDelegate` and
    /// forwards the callbacks on, so `NSApp.delegate as? AppLifecycle` returns
    /// nil — silently, at every call site, with optional chaining turning the
    /// failure into a no-op rather than a crash. That is why "Open FlowTrace"
    /// did nothing: the activation-policy change and the activation were both
    /// skipped, and the log had nothing to show because neither line ever ran.
    ///
    /// Set from a callback that does arrive on this instance, so it is the
    /// object itself rather than a guess about what AppKit is holding.
    @MainActor private(set) static var shared: AppLifecycle?

    /// SwiftUI's `openWindow`, captured from a view that is always alive.
    ///
    /// Only SwiftUI can build a `WindowGroup` window, and only a live view can
    /// reach `openWindow`. The menu-bar popover is not alive until it is
    /// opened, and the workspace is not alive when it is closed, so without
    /// this there is no moment at which the delegate can open the workspace on
    /// its own — which is why clicking the Dock tile with no window did nothing.
    ///
    /// Held from the menu-bar item's label, which exists for as long as the app
    /// does.
    @MainActor var openWindowAction: (() -> Void)?

    /// Everything that has to outlive the main window.
    ///
    /// These used to hang off `RootView`, the `WindowGroup`'s root view, which
    /// tied the capture shortcut to a window being open. The window is now
    /// closed at launch, so they live here instead.
    @MainActor private var hotKey: GlobalHotKey?
    @MainActor private var tapMonitor: ModifierTapMonitor?
    @MainActor private var quickCapture: QuickCaptureController?

    /// True while the capture panel is on screen, so nothing raises the main
    /// window out from under it.
    @MainActor var isCapturing: Bool { quickCapture?.isPresenting ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.shared = self
            guard let model = Self.model else { return }
            // Open the workspace on launch so the app is immediately reachable.
            // It remains a menu-bar resident after the window is closed.
            if Self.wantsMainWindowAtLaunch(model) {
                // First run opens on the main window, so it is a workspace
                // session like any other and gets the same identity.
                enterWorkspace()
            } else {
                closeMainWindows()
            }
            watchMainWindowClosing()
            model.refresh()
            model.startServerIfEnabled()
            model.startRecordingIfEnabled()
            registerCaptureTrigger(model: model)
            watchTriggerChanges(model: model)
        }
        // SwiftUI creates the `WindowGroup` window around the launch, and the
        // exact turn varies; closing once more after it has settled covers it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let model = Self.model,
                      Self.wantsMainWindowAtLaunch(model) == false else { return }
                self?.closeMainWindows()
            }
        }
    }

    /// FlowTrace should always be immediately usable after launch. The
    /// development route/thread switches are retained for targeted launches.
    @MainActor
    private static func wantsMainWindowAtLaunch(_ model: AppModel) -> Bool {
        _ = model
        return true
    }

    /// Closes the main window without touching the panel, the menu-bar popover
    /// or Settings.
    @MainActor
    private func closeMainWindows() {
        for window in NSApp.windows where Self.isMainWindow(window) {
            window.close()
        }
    }

    /// The workspace window, identified by name rather than by shape.
    ///
    /// It used to be "anything that can become main and is not the capture
    /// panel or Settings", which is a description of what the workspace happens
    /// to be rather than of what it is. SwiftUI stamps the window group's own
    /// identifier onto it — `flowtrace.main-AppWindow-1` — so the test can name
    /// the window instead of guessing at it, and nothing transient can be
    /// mistaken for the workspace by the close watcher.
    @MainActor
    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(FlowTraceApp.mainWindowID) == true
    }

    /// The workspace window, if one is open.
    @MainActor
    var mainWindow: NSWindow? {
        NSApp.windows.first(where: { Self.isMainWindow($0) })
    }

    /// Raises the workspace window if one exists.
    @MainActor
    @discardableResult
    func raiseMainWindow() -> Bool {
        guard let existing = mainWindow else { return false }
        existing.makeKeyAndOrderFront(nil)
        return true
    }

    /// Open the workspace, from anywhere.
    ///
    /// One path for every way in — the menu item, the Dock tile, a reopen — so
    /// there is one story about what "open FlowTrace" does. Raises what is
    /// already there rather than building a second window.
    @MainActor
    func openWorkspace() {
        if !raiseMainWindow() { openWindowAction?() }
        revealMainWindow()
    }

    /// True while a reveal is still waiting for SwiftUI to produce the window,
    /// so a second click a moment later waits for the same window rather than
    /// asking for another one.
    @MainActor private var revealing = false

    /// Brings the workspace forward once SwiftUI has built it.
    ///
    /// `openWindow` returns before the window exists, so activating and
    /// ordering front in the same turn acts on nothing. This waits for the
    /// window to appear and then puts it in front — which is also what makes
    /// the Dock-policy change take visible effect.
    @MainActor
    func revealMainWindow(attempt: Int = 0) {
        if attempt == 0 {
            guard !revealing else { return }
            revealing = true
        }
        if let window = mainWindow {
            revealing = false
            enterWorkspace()
            window.makeKeyAndOrderFront(nil)
            Diagnostics.log("workspace revealed")
            return
        }
        // Roughly a second in total. If SwiftUI has not produced a window by
        // then it is not going to, and giving up is better than a timer that
        // outlives the gesture.
        guard attempt < 20 else {
            revealing = false
            Diagnostics.log("workspace never appeared after openWindow")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.revealMainWindow(attempt: attempt + 1) }
        }
    }

    // MARK: - Dock presence

    /// Opening the workspace makes FlowTrace an ordinary application.
    ///
    /// `LSUIElement` is a starting policy, not a life sentence: it is what the
    /// app launches as, and `setActivationPolicy` is what it is from then on.
    /// While the main window is open FlowTrace has a Dock tile, an application
    /// menu and a ⌘-Tab entry, because that is what someone who deliberately
    /// opened a window expects to find.
    ///
    /// The order matters. Raising the policy alone leaves the application menu
    /// behind the previous app's until something activates FlowTrace, so the
    /// activation follows immediately and in the same turn.
    @MainActor
    func enterWorkspace() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            Diagnostics.log("workspace open — regular")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the workspace puts FlowTrace back in the menu bar.
    ///
    /// Only once the window has actually gone: lowering the policy while the
    /// app is still frontmost with a window on screen leaves focus nowhere.
    /// `willClose` arrives before the window leaves `NSApp.windows`, so the
    /// check waits a turn and then asks whether any workspace window is left.
    @MainActor
    private func watchMainWindowClosing() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  MainActor.assumeIsolated({ Self.isMainWindow(window) })
            else { return }
            Diagnostics.log("workspace window closing")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.leaveWorkspaceIfEmpty() }
            }
        }
    }

    @MainActor
    private static func leaveWorkspaceIfEmpty() {
        guard NSApp.activationPolicy() == .regular else { return }
        guard !NSApp.windows.contains(where: { isMainWindow($0) && $0.isVisible })
        else { return }
        NSApp.setActivationPolicy(.accessory)
        Diagnostics.log("workspace closed — accessory")
    }

    // MARK: - Capture trigger

    /// The configured capture trigger opens a small panel over whatever you are doing.
    ///
    /// Registered at launch, before and regardless of first run: the shortcut is
    /// the product's one affordance, and a key that only starts working after a
    /// screen has been dismissed is a key people learn does not work. It
    /// observes nothing until pressed.
    @MainActor
    private func registerCaptureTrigger(model: AppModel) {
        guard quickCapture == nil else { return }
        let controller = QuickCaptureController(model: model)
        quickCapture = controller
        register(model.captureTrigger, controller: controller, model: model)

        // Same panel, reachable from the menu bar for anyone who hasn't learned
        // the shortcut yet.
        NotificationCenter.default.addObserver(
            forName: .flowtraceQuickCapture, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in controller.toggle() }
        }
    }

    /// Re-registers when Settings records a different trigger.
    ///
    /// Observation rather than `onChange`: Settings can be open with no main
    /// window, so there may be no view left to notice.
    @MainActor
    private func watchTriggerChanges(model: AppModel) {
        withObservationTracking {
            _ = model.captureTrigger
            _ = model.triggerReloadToken
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, let controller = self.quickCapture else { return }
                self.register(model.captureTrigger, controller: controller, model: model)
                self.watchTriggerChanges(model: model)
            }
        }
    }

    /// Claims the trigger, replacing whatever was registered before, and reports
    /// back whether the system accepted it.
    @MainActor
    private func register(
        _ trigger: CaptureTrigger, controller: QuickCaptureController, model: AppModel
    ) {
        // Release both mechanisms first: Carbon will not hand over a combination
        // still claimed by this process, and a stale monitor would double-fire.
        hotKey = nil
        tapMonitor?.stop()
        tapMonitor = nil
        model.shortcutFailure = nil

        switch trigger {
        case .chord(let shortcut):
            let key = GlobalHotKey(shortcut: shortcut) {
                Task { @MainActor in controller.toggle() }
            }
            hotKey = key
            model.shortcutFailure = key.failure?.message
            Diagnostics.log(
                key.failure == nil
                    ? "trigger \(trigger.displayString) registered"
                    : "trigger \(trigger.displayString) FAILED — \(key.failure!.message)"
            )

        case .modifierTap(let modifier, let taps):
            // Without Accessibility we cannot see keys pressed in other apps, so
            // say that plainly rather than leaving a dead trigger.
            guard AccessibilityPermission.isGranted else {
                model.shortcutFailure =
                    "Tapping a modifier needs the Accessibility permission. "
                    + "Grant it below, then this starts working."
                Diagnostics.log("trigger \(trigger.displayString) blocked — no Accessibility")
                return
            }
            let monitor = ModifierTapMonitor(key: modifier, taps: taps) {
                Task { @MainActor in controller.toggle() }
            }
            monitor.start()
            tapMonitor = monitor
            Diagnostics.log("trigger \(trigger.displayString) watching")
        }
    }

    // MARK: - Staying alive

    /// Closing the window puts FlowTrace away; it does not stop it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Activating FlowTrace must not drag the main window along behind the
    /// capture panel — that is the whole point of the panel.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            guard !isCapturing else { return true }
            // Clicking the Dock tile, or launching an already-running FlowTrace,
            // is the same deliberate act as choosing Open FlowTrace — so it is
            // the same call, and it works whether or not a window exists.
            openWorkspace()
            return true
        }
    }

    /// The recorder closes its own open span on termination — see
    /// `ActivityRecorder.init`. This is here for the log line only.
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.log("app terminating")
    }
}

/// Starting FlowTrace at login.
///
/// Without this the capture shortcut is dead every morning until the user
/// remembers to launch an app whose whole purpose is to be there when they
/// didn't think to ask for it.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state. macOS may require approval in System
    /// Settings, in which case the status becomes `.requiresApproval` and the
    /// caller should say so rather than reporting success.
    @discardableResult
    static func set(_ enabled: Bool) -> SMAppService.Status {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Diagnostics.log("launch at login failed: \(error.localizedDescription)")
        }
        return SMAppService.mainApp.status
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "FlowTrace starts when you log in."
        case .requiresApproval: "Approve FlowTrace in System Settings → General → Login Items."
        case .notFound: "Move FlowTrace to /Applications first."
        default: "FlowTrace does not start automatically."
        }
    }
}

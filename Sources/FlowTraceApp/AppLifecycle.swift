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
            guard let model = Self.model else { return }
            // FlowTrace starts as what it is: a key and a menu-bar item. The
            // main window is a place to go, not the thing that opens — except
            // on the very first launch, where the first-run screen is the only
            // thing there is to do.
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

    /// The two reasons to open on the main window rather than the menu bar: a
    /// first run, where the first-run screen is the only thing there is to do,
    /// and `FLOWTRACE_OPEN_ROUTE`, the development switch that launches
    /// straight onto a screen so it can be screenshotted.
    @MainActor
    private static func wantsMainWindowAtLaunch(_ model: AppModel) -> Bool {
        if !model.consent.hasCompletedOnboarding { return true }
        return ProcessInfo.processInfo.environment["FLOWTRACE_OPEN_ROUTE"] != nil
            || ProcessInfo.processInfo.environment["FLOWTRACE_OPEN_THREAD"] != nil
    }

    /// Closes the main window without touching the panel, the menu-bar popover
    /// or Settings.
    @MainActor
    private func closeMainWindows() {
        for window in NSApp.windows where Self.isMainWindow(window) {
            window.close()
        }
    }

    /// The `WindowGroup` window, identified by what it is rather than by class:
    /// the panel refuses main status, the popover and status item are not
    /// closable windows, and Settings carries its own identifier.
    @MainActor
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        guard window.canBecomeMain, !(window is QuickCapturePanel) else { return false }
        return window.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") != true
    }

    /// Raises the main window if one exists. Creating one is SwiftUI's job —
    /// the menu bar uses `openWindow(id:)`, which reuses this window when it is
    /// already open and builds it when it is not.
    @MainActor
    @discardableResult
    func raiseMainWindow() -> Bool {
        guard let existing = NSApp.windows.first(where: { Self.isMainWindow($0) })
        else { return false }
        existing.makeKeyAndOrderFront(nil)
        return true
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

    /// ⌥Space opens a small panel over whatever you are doing.
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
            guard !isCapturing, !hasVisibleWindows else { return true }
            // Clicking the Dock tile is the same deliberate act as choosing
            // Open FlowTrace, so it gets the same treatment.
            if raiseMainWindow() { enterWorkspace() }
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

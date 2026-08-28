import AppKit
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
/// So: closing the window hides it, quitting is explicit, and the menubar is the
/// permanent presence.
final class AppLifecycle: NSObject, NSApplicationDelegate {
    /// Closing the window puts FlowTrace away; it does not stop it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the dock icon with no window open brings the window back rather
    /// than doing nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Close the open activity span on the way out, so the last app of the day
    /// doesn't appear to have been used all night.
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

import AppKit
import FlowTraceCore

/// Fires when a modifier key is tapped on its own.
///
/// The hard part isn't detecting the key — it's *not* firing when the key is
/// doing its actual job. Option is held constantly as part of other shortcuts, so
/// a tap only counts when all of these hold:
///
///   - the key went down and came back up quickly (a tap, not a hold),
///   - no other key was pressed while it was down (it wasn't a modifier),
///   - no other modifier joined it (⌥⇧ is not a tap of ⌥),
///   - the mouse wasn't clicked or dragged (⌥-drag is a gesture, not a tap).
///
/// Needs the Accessibility permission: observing keys pressed in other apps is
/// exactly what that permission gates.
@MainActor
final class ModifierTapMonitor {
    /// How quickly the key must go down and up to count as a tap rather than a hold.
    private let tapWindow: TimeInterval = 0.35
    /// How close two taps must be to count as a double tap.
    private let doubleTapWindow: TimeInterval = 0.45

    private let key: ModifierKey
    private let requiredTaps: Int
    private let action: () -> Void

    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var disqualified = false
    private var lastTapAt: Date?

    init(key: ModifierKey, taps: Int, action: @escaping () -> Void) {
        self.key = key
        self.requiredTaps = max(1, taps)
        self.action = action
    }

    func start() {
        stop()
        guard AccessibilityPermission.isGranted else {
            Diagnostics.log("modifier tap: Accessibility not granted, not monitoring")
            return
        }

        // Global monitors see other apps; local monitors see our own windows.
        // Both are needed, or the trigger dies whenever FlowTrace is focused.
        add(global: [.flagsChanged]) { [weak self] in self?.handleFlags($0) }
        add(global: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
            [weak self] _ in self?.disqualified = true
        }
        add(local: [.flagsChanged]) { [weak self] in self?.handleFlags($0) }
        add(local: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
            [weak self] _ in self?.disqualified = true
        }

        Diagnostics.log("modifier tap: watching \(key.label) x\(requiredTaps)")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pressedAt = nil
        lastTapAt = nil
    }

    deinit {
        // NSEvent.removeMonitor is safe from any thread.
        monitors.forEach(NSEvent.removeMonitor)
    }

    // MARK: - Detection

    private func handleFlags(_ event: NSEvent) {
        let isOurKey = event.keyCode == key.keyCode
        let isDown = event.modifierFlags.contains(key.flag)

        guard isOurKey else {
            // Another modifier joined in — whatever is happening, it isn't a
            // bare tap of our key.
            if pressedAt != nil { disqualified = true }
            return
        }

        if isDown {
            pressedAt = Date()
            disqualified = false
            return
        }

        // Released.
        defer { pressedAt = nil }
        guard let pressedAt, !disqualified else { return }
        guard Date().timeIntervalSince(pressedAt) <= tapWindow else { return }

        registerTap()
    }

    private func registerTap() {
        let now = Date()
        guard requiredTaps > 1 else {
            fire()
            return
        }
        if let lastTapAt, now.timeIntervalSince(lastTapAt) <= doubleTapWindow {
            self.lastTapAt = nil
            fire()
        } else {
            lastTapAt = now
        }
    }

    private func fire() {
        Diagnostics.log("modifier tap: \(key.label) fired")
        action()
    }

    // MARK: - Monitor plumbing

    private func add(global mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
        }
        if let monitor { monitors.append(monitor) }
    }

    private func add(local mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }
        if let monitor { monitors.append(monitor) }
    }
}

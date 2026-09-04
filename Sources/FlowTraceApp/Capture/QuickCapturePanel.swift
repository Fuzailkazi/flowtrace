import AppKit
import SwiftUI
import FlowTraceCore

/// A small floating panel that appears over whatever you're doing.
///
/// Deliberately not the main window: pressing the key while reading a page should
/// not throw you into another app. `.nonactivatingPanel` plus `.floating` lets the
/// panel take keyboard focus for the few seconds you need it, then hand focus
/// straight back when it closes.
final class QuickCapturePanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            // Deliberately *not* .nonactivatingPanel. That flag stops the panel
            // becoming key even when the app is activated, which showed up in the
            // log as "key: false" — the panel appeared and then silently refused
            // every keystroke. Focus is handed back to the previous app on close,
            // which gets the same result without the flag.
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Follow the user onto other spaces and over full-screen apps — the whole
        // point is that it reaches you where you already are.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = content
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // A panel must opt in to keyboard focus, or the note field cannot be typed in.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Centres slightly above the middle of the screen the pointer is on — where
    /// the eye already is, rather than dead centre.
    func positionOverActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = self.frame.size
        setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.12
        ))
    }
}

/// Owns the panel's lifecycle. One instance lives for the life of the app.
@MainActor
final class QuickCaptureController {
    private var panel: QuickCapturePanel?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Snapshots where the user is, then shows the panel over it.
    func toggle() {
        Diagnostics.log("quick-capture toggle (visible: \(panel?.isVisible ?? false))")
        if let panel, panel.isVisible {
            dismiss()
            return
        }
        present()
    }

    private func present() {
        let snapshot = FrontmostSnapshot.capture()
        let previousApp = NSWorkspace.shared.frontmostApplication

        let view = QuickCaptureView(
            model: model,
            snapshot: snapshot,
            onFinish: { [weak self] in self?.dismiss(returningTo: previousApp) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 200)

        let panel = QuickCapturePanel(content: hosting)
        panel.positionOverActiveScreen()
        self.panel = panel

        // FlowTrace has a dock icon, so it is a "regular" app — and a regular
        // app's window cannot take keyboard focus while another app is active,
        // however floating the panel is. Without activating first, the panel
        // appears but refuses to accept a single keystroke.
        //
        // Activating shows the panel only: the main window is never ordered
        // front, and focus is handed straight back on dismiss.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Key status is not settled synchronously, so a reading taken here is
        // meaningless. Check on the next pass and insist if it didn't take.
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel else { return }
            if !panel.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKey()
            }
            // Read again once the window server has settled. The immediate
            // reading above is taken in the same turn as `makeKey()`, which
            // has not taken effect yet — it reported "accepts typing: false"
            // on panels that went on to accept typing perfectly well, and a
            // false alarm here is expensive: it argues for re-architecting the
            // app around a bug that may not exist.
            //
            // What matters is not whether the panel is key but whether the
            // *field* has the keyboard: a key panel whose text field never
            // became first responder swallows keystrokes just as completely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let panel = self?.panel else { return }
                let responder = panel.firstResponder
                let fieldHasKeyboard = responder is NSTextView
                Diagnostics.log(
                    "panel over \(snapshot.appName) — key: \(panel.isKeyWindow), "
                    + "field ready: \(fieldHasKeyboard), "
                    + "responder: \(responder.map { String(describing: type(of: $0)) } ?? "none")"
                )
            }
        }
    }

    func dismiss(returningTo app: NSRunningApplication? = nil) {
        panel?.orderOut(nil)
        panel = nil
        // Hand focus back to whatever the user was actually doing.
        if let app {
            app.activate()
            Diagnostics.log("focus returned to \(app.localizedName ?? "previous app")")
        }
    }
}

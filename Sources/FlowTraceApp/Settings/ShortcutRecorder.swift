import SwiftUI
import AppKit

/// Click, then press the combination you want.
///
/// Uses a local event monitor rather than first-responder key handling: while
/// recording, every key press in the window is swallowed here, so pressing ⌘W to
/// set a shortcut doesn't close the window instead.
struct ShortcutRecorder: View {
    @Binding var shortcut: HotKeyShortcut
    var onRecorded: (() -> Void)?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                recording.toggle()
            } label: {
                Text(recording ? "Press a key…" : shortcut.displayString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            .help("Click, then press the combination you want")

            if recording {
                Text("esc to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if shortcut != .default {
                Button("Reset") {
                    shortcut = .default
                    onRecorded?()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            if rejected {
                Text("Needs a modifier — try ⌘, ⌥, ⌃ or ⇧ with it")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: recording) { _, isRecording in
            isRecording ? startListening() : stopListening()
        }
        .onDisappear(perform: stopListening)
    }

    private func startListening() {
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape abandons recording rather than becoming the shortcut.
            if event.keyCode == 53 {
                recording = false
                return nil
            }
            if let recorded = HotKeyShortcut.from(event: event) {
                shortcut = recorded
                recording = false
                onRecorded?()
            } else {
                // A bare letter would fire every time it was typed anywhere.
                rejected = true
            }
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

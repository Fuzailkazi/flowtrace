import AppKit
import Carbon.HIToolbox
import FlowTraceCore

let diagnosticDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
Diagnostics.directory = diagnosticDirectory
defer { try? FileManager.default.removeItem(at: diagnosticDirectory) }

// This executable has its own defaults domain; never touches the app's settings.
let defaults = UserDefaults.standard
defaults.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
defer { defaults.removePersistentDomain(forName: ProcessInfo.processInfo.processName) }

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL"): \(message)")
    if !condition { failures += 1 }
}

let chosen = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_N),
                            carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "N")
CaptureTrigger.chord(chosen).save()
check(CaptureTrigger.load() == .chord(chosen), "A user-selected Control–Option–N survives reload")
check(CaptureTrigger.load() == .chord(chosen), "Repeated loads preserve the chosen shortcut")

let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                           timestamp: 0, windowNumber: 0, context: nil,
                           characters: "n", charactersIgnoringModifiers: "n", isARepeat: false,
                           keyCode: UInt16(kVK_ANSI_N))!
check(HotKeyShortcut.from(event: event) == chosen, "Recording preserves Control and Option modifiers")
exit(failures == 0 ? 0 : 1)

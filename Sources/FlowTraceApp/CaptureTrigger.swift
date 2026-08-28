import AppKit
import Carbon.HIToolbox

/// A modifier key, distinguished by side.
///
/// The side matters: people reach for left Option with the same hand that is
/// already on the keyboard, and leaving right Option free means the modifier
/// still works normally when they want it to.
enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case leftOption, rightOption
    case leftCommand, rightCommand
    case leftControl, rightControl
    case leftShift, rightShift

    var label: String {
        switch self {
        case .leftOption: "Left ⌥"
        case .rightOption: "Right ⌥"
        case .leftCommand: "Left ⌘"
        case .rightCommand: "Right ⌘"
        case .leftControl: "Left ⌃"
        case .rightControl: "Right ⌃"
        case .leftShift: "Left ⇧"
        case .rightShift: "Right ⇧"
        }
    }

    /// Virtual key code reported by the `flagsChanged` event for this physical key.
    var keyCode: UInt16 {
        switch self {
        case .leftOption: UInt16(kVK_Option)
        case .rightOption: UInt16(kVK_RightOption)
        case .leftCommand: UInt16(kVK_Command)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .leftControl: UInt16(kVK_Control)
        case .rightControl: UInt16(kVK_RightControl)
        case .leftShift: UInt16(kVK_Shift)
        case .rightShift: UInt16(kVK_RightShift)
        }
    }

    /// The flag that is present while this key is held down.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        case .leftControl, .rightControl: .control
        case .leftShift, .rightShift: .shift
        }
    }
}

/// How the quick-capture panel is summoned.
enum CaptureTrigger: Equatable, Codable, Sendable {
    /// A normal shortcut: a key plus modifiers. Registered with Carbon, needs no
    /// permission, cannot fire by accident.
    case chord(HotKeyShortcut)

    /// Tapping a modifier on its own. Reads more naturally, but requires the
    /// Accessibility permission and can be triggered accidentally.
    case modifierTap(key: ModifierKey, taps: Int)

    static let `default` = CaptureTrigger.chord(.default)

    var displayString: String {
        switch self {
        case .chord(let shortcut):
            shortcut.displayString
        case .modifierTap(let key, let taps):
            taps > 1 ? "\(key.label) ×\(taps)" : key.label
        }
    }

    /// True when this trigger can only work with Accessibility granted.
    var needsAccessibility: Bool {
        if case .modifierTap = self { return true }
        return false
    }

    // MARK: - Persistence

    private static let defaultsKey = "flowtrace.captureTrigger"
    private static let chosenKey = "flowtrace.captureTriggerChosen"

    /// Whether the user has actually picked a shortcut.
    ///
    /// Nothing is registered until they have. A silent default meant the key that
    /// opens the note panel was one nobody chose, buried three sections into a
    /// Settings pane reached through a "More" menu — so it may as well not have
    /// been configurable at all.
    static var hasBeenChosen: Bool {
        UserDefaults.standard.bool(forKey: chosenKey)
    }

    /// The suggestion offered during setup. Only becomes the shortcut if the user
    /// accepts it.
    static let suggestion = CaptureTrigger.chord(HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        carbonModifiers: UInt32(controlKey | optionKey),
        keyLabel: "N"
    ))

    static func load() -> CaptureTrigger {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(CaptureTrigger.self, from: data)
        else { return suggestion }
        return decoded
    }

    /// Persists the choice and records that one was made.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UserDefaults.standard.set(true, forKey: Self.chosenKey)
    }
}

/// Whether macOS will let us observe modifier keys at all.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its Accessibility prompt. Returns the state right now —
    /// granting happens in System Settings, so this is expected to be false the
    /// first time and become true later without the app restarting.
    @discardableResult
    static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

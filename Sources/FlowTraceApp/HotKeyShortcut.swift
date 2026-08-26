import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, as chosen by the user.
///
/// The character the key produces is stored alongside its code rather than being
/// derived later: reverse-mapping a key code to a label needs the current input
/// source and gets it wrong for non-US layouts. Recording what the key actually
/// typed is both simpler and correct.
struct HotKeyShortcut: Equatable, Codable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask — `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    var carbonModifiers: UInt32
    /// What to show the user for the non-modifier key, e.g. "Space", "J", "F5".
    var keyLabel: String

    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "Space"
    )

    /// Apple's canonical modifier order: control, option, shift, command.
    var displayString: String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + keyLabel
    }

    // MARK: - Recording

    /// Builds a shortcut from a key press, or returns nil if it isn't usable as a
    /// global shortcut.
    ///
    /// A bare letter would fire every time the user typed it in any app, so at
    /// least one modifier is required — except for function keys, which are
    /// already dedicated.
    static func from(event: NSEvent) -> HotKeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }

        let code = UInt32(event.keyCode)
        guard let label = label(for: event) else { return nil }
        guard carbon != 0 || isFunctionKey(code) else { return nil }

        return HotKeyShortcut(keyCode: code, carbonModifiers: carbon, keyLabel: label)
    }

    private static func isFunctionKey(_ code: UInt32) -> Bool {
        let functionKeys: Set<UInt32> = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        ]
        return functionKeys.contains(code)
    }

    /// Keys that produce no printable character, or whose character would be
    /// unreadable in a shortcut field.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
        kVK_Delete: "Delete", kVK_ForwardDelete: "⌦", kVK_Escape: "Escape",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func label(for event: NSEvent) -> String? {
        if let named = namedKeys[Int(event.keyCode)] { return named }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty
        else { return nil }
        return characters.uppercased()
    }

    // MARK: - Persistence

    private static let defaultsKey = "flowtrace.captureShortcut"

    static func load() -> HotKeyShortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

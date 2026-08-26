import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut for quick capture.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor:
/// the Carbon API needs no Accessibility permission, so capture works the moment
/// the app launches instead of after a trip through System Settings.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static nonisolated(unsafe) var action: (() -> Void)?

    /// ⌥Space by default.
    init?(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
          action: @escaping () -> Void) {
        Self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.action?() }
                return noErr
            },
            1, &eventType, nil, &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x464C_5443), id: 1) // 'FLTC'
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        // Another app may already own this combination; capture still works from
        // the menubar and the in-app shortcut, so this is not fatal.
        guard registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

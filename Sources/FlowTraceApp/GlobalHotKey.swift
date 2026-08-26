import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor:
/// the Carbon API needs no Accessibility permission, so capture works the moment
/// the app launches instead of after a trip through System Settings.
final class GlobalHotKey {
    /// Why a shortcut isn't working, so Settings can say something useful rather
    /// than leaving the user pressing a dead key.
    enum Failure: Equatable {
        /// Another application already owns this combination.
        case alreadyTaken
        case systemRefused(OSStatus)

        var message: String {
            switch self {
            case .alreadyTaken:
                "Another app already uses this shortcut. Pick a different one."
            case .systemRefused(let status):
                "macOS refused this shortcut (error \(status)). Pick a different one."
            }
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static nonisolated(unsafe) var action: (() -> Void)?

    private(set) var failure: Failure?

    /// Registers `shortcut`. Check `failure` afterwards — a clash with another
    /// app is reported, not thrown, because it is a normal thing to hit.
    init(shortcut: HotKeyShortcut, action: @escaping () -> Void) {
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
        guard installStatus == noErr else {
            failure = .systemRefused(installStatus)
            return
        }

        let identifier = EventHotKeyID(signature: OSType(0x464C_5443), id: 1) // 'FLTC'
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            // eventHotKeyExistsErr is what you get when something else holds it.
            failure = status == OSStatus(eventHotKeyExistsErr) ? .alreadyTaken : .systemRefused(status)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

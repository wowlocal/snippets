import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts for opening Snippets and starting Secure Paste.
///
/// Carbon's `RegisterEventHotKey` is still the public API for a shortcut that
/// fires while another app is frontmost and consumes an ordinary key event. It
/// needs no Accessibility trust and works regardless of activation policy —
/// including while the app is hidden to the menu bar. Secure Event Input is the
/// intentional exception: macOS may suppress all third-party global shortcuts
/// while a password field owns protected keyboard entry.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    static let defaultsKey = "globalOpenHotkeyEnabled"

    /// How the shortcut is rendered in menus and settings copy.
    static let displayString = "⌘\\"
    static let securePasteDisplayString = "⌥\\"

    /// `\` by physical key position: Carbon matches virtual key codes, not the
    /// character the active keyboard layout produces.
    private static let keyCode = UInt32(kVK_ANSI_Backslash)
    private static let openModifierFlags = UInt32(cmdKey)
    private static let securePasteModifierFlags = UInt32(optionKey)
    private static let signature = OSType(0x534E5054) // 'SNPT'
    private static let openIdentifier: UInt32 = 1
    private static let securePasteIdentifier: UInt32 = 2

    /// Called on the main thread each time the shortcut fires.
    var onTrigger: (() -> Void)?
    var onSecurePasteTrigger: (() -> Void)?

    /// True when a shortcut is enabled but macOS refused its registration,
    /// which normally means another app already owns that key combination.
    private(set) var openRegistrationFailed = false
    private(set) var securePasteRegistrationFailed = false

    var registrationFailed: Bool {
        openRegistrationFailed || securePasteRegistrationFailed
    }

    /// Enabled by default; a missing key means the user never chose.
    var isEnabled: Bool {
        get {
            guard let stored = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool else {
                return true
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            applyRegistration()
            postChangeNotification()
        }
    }

    var isActive: Bool {
        openHotKeyRef != nil
    }

    var isSecurePasteActive: Bool { securePasteHotKeyRef != nil }

    private var openHotKeyRef: EventHotKeyRef?
    private var securePasteHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Registers or unregisters the shortcut to match the preference.
    /// Idempotent, and retries a previously failed registration — reopening
    /// Settings after quitting the conflicting app is enough to recover.
    func syncRegistration() {
        if applyRegistration() {
            postChangeNotification()
        }
    }

    /// Returns `true` when the shortcut changed between claimed and released,
    /// which is what the menu bar hint and Settings copy key off.
    @discardableResult
    private func applyRegistration() -> Bool {
        let openWasActive = isActive
        let securePasteWasActive = isSecurePasteActive

        if isEnabled {
            register()
        } else {
            unregister()
        }

        return isActive != openWasActive || isSecurePasteActive != securePasteWasActive
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .snippetsGlobalHotkeyChanged, object: nil)
    }

    private func register() {
        guard installEventHandlerIfNeeded() else {
            openRegistrationFailed = openHotKeyRef == nil
            securePasteRegistrationFailed = securePasteHotKeyRef == nil
            return
        }

        var firstFailure: OSStatus?

        if openHotKeyRef == nil {
            let result = registerHotKey(
                modifierFlags: Self.openModifierFlags,
                identifier: Self.openIdentifier
            )
            openHotKeyRef = result.reference
            openRegistrationFailed = result.reference == nil
            if result.reference == nil { firstFailure = firstFailure ?? result.status }
        }

        if securePasteHotKeyRef == nil {
            let result = registerHotKey(
                modifierFlags: Self.securePasteModifierFlags,
                identifier: Self.securePasteIdentifier
            )
            securePasteHotKeyRef = result.reference
            securePasteRegistrationFailed = result.reference == nil
            if result.reference == nil { firstFailure = firstFailure ?? result.status }
        }

        if let firstFailure {
            recordRegistrationFailure(firstFailure)
        }
    }

    private func registerHotKey(
        modifierFlags: UInt32,
        identifier: UInt32
    ) -> (reference: EventHotKeyRef?, status: OSStatus) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        // Register and listen on the dispatcher target: in a Cocoa app the hot
        // key event reaches us through NSApplication's Carbon event dispatch,
        // so the handler has to sit on the same target the key is bound to.
        let status = RegisterEventHotKey(
            Self.keyCode,
            modifierFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return (nil, status == noErr ? OSStatus(eventInternalErr) : status)
        }
        return (reference, status)
    }

    private func recordRegistrationFailure(_ status: OSStatus) {
        Diagnostics.record(.storageFailure(
            area: .globalHotkey,
            operation: .register,
            failure: DiagnosticFailure(family: .security, code: Int(status)),
            attempt: nil))
    }

    private func unregister() {
        if let openHotKeyRef {
            UnregisterEventHotKey(openHotKeyRef)
            self.openHotKeyRef = nil
        }
        if let securePasteHotKeyRef {
            UnregisterEventHotKey(securePasteHotKeyRef)
            self.securePasteHotKeyRef = nil
        }
        openRegistrationFailed = false
        securePasteRegistrationFailed = false
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }

                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }

                // Carbon dispatches hot key events on the main run loop.
                return MainActor.assumeIsolated {
                    GlobalHotkeyManager.shared.handleHotKey(firedID)
                }
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        guard status == noErr else {
            Diagnostics.record(.storageFailure(
                area: .globalHotkey,
                operation: .register,
                failure: DiagnosticFailure(family: .security, code: Int(status)),
                attempt: nil))
            return false
        }

        eventHandler = handlerRef
        return true
    }

    private func handleHotKey(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }

        switch id.id {
        case Self.openIdentifier:
            onTrigger?()
            return noErr
        case Self.securePasteIdentifier:
            onSecurePasteTrigger?()
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }
}

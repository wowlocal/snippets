import AppKit
import Carbon.HIToolbox

/// System-wide ⌘\ shortcut that brings Snippets to the front from any app.
///
/// Carbon's `RegisterEventHotKey` is still the only public API for a shortcut
/// that fires while another app is frontmost and consumes the key event. It
/// needs no Accessibility trust, so the shortcut works even before expansion
/// permissions are granted, and it fires regardless of activation policy —
/// including while the app is hidden to the menu bar.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    static let defaultsKey = "globalOpenHotkeyEnabled"

    /// How the shortcut is rendered in menus and settings copy.
    static let displayString = "⌘\\"

    /// `\` by physical key position: Carbon matches virtual key codes, not the
    /// character the active keyboard layout produces.
    private static let keyCode = UInt32(kVK_ANSI_Backslash)
    private static let modifierFlags = UInt32(cmdKey)
    private static let signature = OSType(0x534E5054) // 'SNPT'
    private static let identifier: UInt32 = 1

    /// Called on the main thread each time the shortcut fires.
    var onTrigger: (() -> Void)?

    /// True when the shortcut is enabled but macOS refused the registration,
    /// which normally means another app already owns ⌘\.
    private(set) var registrationFailed = false

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
        hotKeyRef != nil
    }

    private var hotKeyRef: EventHotKeyRef?
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
        let wasActive = isActive

        if isEnabled {
            register()
        } else {
            unregister()
        }

        return isActive != wasActive
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .snippetsGlobalHotkeyChanged, object: nil)
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        // Register and listen on the dispatcher target: in a Cocoa app the hot
        // key event reaches us through NSApplication's Carbon event dispatch,
        // so the handler has to sit on the same target the key is bound to.
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifierFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            registrationFailed = true
            NSLog("Global hotkey \(Self.displayString) registration failed (status \(status))")
            return
        }

        hotKeyRef = reference
        registrationFailed = false
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registrationFailed = false
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

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
            NSLog("Global hotkey event handler installation failed (status \(status))")
            return
        }

        eventHandler = handlerRef
    }

    private func handleHotKey(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature, id.id == Self.identifier else {
            return OSStatus(eventNotHandledErr)
        }

        onTrigger?()
        return noErr
    }
}

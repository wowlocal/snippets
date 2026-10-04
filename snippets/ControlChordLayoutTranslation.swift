import AppKit
import Carbon.HIToolbox

/// AppKit looks up emacs-style text bindings (^A, ^E, ^B, ^F, ^N, ^P, ^K…) by
/// `charactersIgnoringModifiers`, which a Cyrillic or other non-Latin layout fills
/// with its own letter: Control-B arrives as ^и and does nothing. Command shortcuts
/// already fall back to the user's Latin layout; give Control chords typed into
/// this app's windows and pickers the same fallback. Physical keys, `characters`
/// (already the ASCII control code) and every other field stay as typed.
enum ControlChordLayoutTranslation {
    /// Characters a key produces on a Latin layout with the given modifiers.
    typealias Layout = (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> String?

    static func installMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            translated(event, layout: currentLatinLayout) ?? event
        }
    }

    /// Returns the chord as the Latin layout would have reported it, or nil when
    /// the event is not a Control chord typed on a non-Latin layout.
    static func translated(_ event: NSEvent, layout: Layout) -> NSEvent? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), !flags.contains(.command),
              let typed = event.charactersIgnoringModifiers, !typed.isEmpty,
              // Arrows and function keys report private-use characters; leave them alone.
              typed.unicodeScalars.allSatisfy({ !$0.isASCII && !(0xE000...0xF8FF).contains($0.value) })
        else { return nil }
        // An input method owns its keys while it is composing.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return nil }
        guard let latin = layout(event.keyCode, flags.intersection(.shift)),
              latin.unicodeScalars.count == 1,
              let scalar = latin.unicodeScalars.first, (0x21...0x7E).contains(scalar.value)
        else { return nil }

        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil,
            characters: event.characters ?? latin, charactersIgnoringModifiers: latin,
            isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    /// The Latin layout macOS itself uses for Command shortcuts.
    static func currentLatinLayout(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else { return nil }
        return characters(in: source, keyCode: keyCode, modifiers: modifiers)
    }

    static func characters(
        in source: TISInputSource,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var carbonModifiers = 0
        if modifiers.contains(.shift) { carbonModifiers |= shiftKey }
        if modifiers.contains(.option) { carbonModifiers |= optionKey }
        if modifiers.contains(.control) { carbonModifiers |= controlKey }
        var deadKeyState: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                UInt32((carbonModifiers >> 8) & 0xFF), UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                units.count, &length, &units)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: units, count: length)
    }
}

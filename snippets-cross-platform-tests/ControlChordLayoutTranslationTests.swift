import XCTest

#if os(macOS)
import AppKit
import Carbon.HIToolbox
@testable import Snippets_Debug

@MainActor
final class ControlChordLayoutTranslationTests: XCTestCase {
    func testRussianControlChordsReportLatinBindingCharacters() throws {
        let russian = try RussianControlChord.source("com.apple.keylayout.Russian")
        for (code, latin) in [(0, "a"), (14, "e"), (11, "b"), (3, "f"), (45, "n"), (35, "p"),
                              (40, "k"), (2, "d"), (4, "h")] {
            let keyCode = UInt16(code)
            let typed = try XCTUnwrap(ControlChordLayoutTranslation.characters(
                in: russian, keyCode: keyCode, modifiers: .control))
            let letter = try XCTUnwrap(ControlChordLayoutTranslation.characters(
                in: russian, keyCode: keyCode, modifiers: []))
            XCTAssertFalse(letter.unicodeScalars.allSatisfy(\.isASCII), "Fixture must be a non-Latin layout")
            let event = try RussianControlChord.key(code: keyCode, characters: typed, unmodified: letter)

            let translated = try XCTUnwrap(ControlChordLayoutTranslation.translated(
                event, layout: RussianControlChord.usLayout()))
            XCTAssertEqual(translated.charactersIgnoringModifiers, latin)
            XCTAssertEqual(translated.characters, typed, "Control codes already match the Latin layout")
            XCTAssertEqual(translated.keyCode, keyCode)
            XCTAssertEqual(translated.modifierFlags, event.modifierFlags)
            XCTAssertEqual(translated.timestamp, event.timestamp)
        }

        let shiftedRepeat = try RussianControlChord.key(code: 11, characters: "\u{2}", unmodified: "И",
            modifiers: [.control, .shift], isARepeat: true)
        let translated = try XCTUnwrap(ControlChordLayoutTranslation.translated(
            shiftedRepeat, layout: RussianControlChord.usLayout()))
        XCTAssertEqual(translated.charactersIgnoringModifiers, "B")
        XCTAssertTrue(translated.isARepeat)
    }

    func testLatinCommandPlainFunctionAndPunctuationKeysStayAsTyped() throws {
        var lookups = 0
        let layout: ControlChordLayoutTranslation.Layout = { _, _ in
            lookups += 1
            return "b"
        }
        let untouched = [
            try RussianControlChord.key(code: 11, characters: "\u{2}", unmodified: "b"),
            try RussianControlChord.key(code: 11, characters: "и", unmodified: "и", modifiers: []),
            try RussianControlChord.key(code: 11, characters: "и", unmodified: "и", modifiers: [.command, .control]),
            try RussianControlChord.key(code: 123, characters: "\u{F702}", unmodified: "\u{F702}",
                modifiers: [.control, .function, .numericPad]),
            try RussianControlChord.key(code: 44, characters: "\u{1F}", unmodified: "."),
            try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .control,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\u{2}",
                charactersIgnoringModifiers: "и", isARepeat: false, keyCode: 11)),
        ]
        for event in untouched {
            XCTAssertNil(ControlChordLayoutTranslation.translated(event, layout: layout))
        }
        XCTAssertEqual(lookups, 0)

        let unprintable = try RussianControlChord.key(code: 11, characters: "\u{2}", unmodified: "и")
        XCTAssertNil(ControlChordLayoutTranslation.translated(unprintable, layout: { _, _ in "\u{2}" }))
        XCTAssertNil(ControlChordLayoutTranslation.translated(unprintable, layout: { _, _ in nil }))
    }

    func testLaunchMonitorTranslatesChordsTheApplicationDispatches() throws {
        guard ControlChordLayoutTranslation.currentLatinLayout(keyCode: 11, modifiers: []) == "b",
              ControlChordLayoutTranslation.currentLatinLayout(keyCode: 3, modifiers: []) == "f"
        else { throw XCTSkip("Needs a QWERTY Latin layout to predict ^B and ^F") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("Entry", replacementRange: NSRange(location: NSNotFound, length: 0))
        // AppKit dispatches keys only to a window that can take them; the test
        // host is not activated, so no other application loses focus.
        window.makeKeyAndOrderFront(nil)

        // Untranslated, as the Russian layout reports them. Only this test host's
        // own event dispatch is used; nothing reaches another application.
        NSApp.sendEvent(try RussianControlChord.key(code: 11, characters: "\u{2}", unmodified: "и", window: window))
        NSApp.sendEvent(try RussianControlChord.key(code: 11, characters: "\u{2}", unmodified: "и", window: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        NSApp.sendEvent(try RussianControlChord.key(code: 3, characters: "\u{6}", unmodified: "а", window: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.string, "Entry")
    }

    func testInputMethodCompositionKeepsItsControlChords() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let event = try RussianControlChord.key(code: 11, characters: "\u{2}", unmodified: "и", window: window)
        let us = try RussianControlChord.usLayout()
        XCTAssertTrue(event.window === window)
        XCTAssertNotNil(ControlChordLayoutTranslation.translated(event, layout: us))

        editor.setMarkedText("ни", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertNil(ControlChordLayoutTranslation.translated(event, layout: us))
    }
}

/// Control chords as AppKit reports them on the Russian layout, then as the app's
/// launch-time monitor hands them on with US as the user's Latin layout.
@MainActor
enum RussianControlChord {
    static func translated(code: UInt16, window: NSWindow) throws -> NSEvent {
        let russian = try source("com.apple.keylayout.Russian")
        let event = try key(code: code,
            characters: try XCTUnwrap(ControlChordLayoutTranslation.characters(
                in: russian, keyCode: code, modifiers: .control)),
            unmodified: try XCTUnwrap(ControlChordLayoutTranslation.characters(
                in: russian, keyCode: code, modifiers: [])),
            window: window)
        return try XCTUnwrap(ControlChordLayoutTranslation.translated(event, layout: try usLayout()))
    }

    static func usLayout() throws -> ControlChordLayoutTranslation.Layout {
        let us = try source("com.apple.keylayout.US")
        return { ControlChordLayoutTranslation.characters(in: us, keyCode: $0, modifiers: $1) }
    }

    static func source(_ identifier: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return try XCTUnwrap(sources?.first, "\(identifier) is installed with every macOS")
    }

    static func key(
        code: UInt16,
        characters: String,
        unmodified: String,
        modifiers: NSEvent.ModifierFlags = .control,
        isARepeat: Bool = false,
        window: NSWindow? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 42, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: unmodified,
            isARepeat: isARepeat, keyCode: code))
    }
}
#endif

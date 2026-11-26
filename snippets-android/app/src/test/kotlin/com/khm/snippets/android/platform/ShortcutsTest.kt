package com.khm.snippets.android.platform

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ShortcutsTest {
    @Test
    fun ctrlShortcutsMap() {
        assertEquals(AppShortcut.Search, appShortcutFor(KeyEvent.KEYCODE_F, ctrl = true, shift = false))
        assertEquals(AppShortcut.NewSnippet, appShortcutFor(KeyEvent.KEYCODE_N, ctrl = true, shift = false))
        assertEquals(AppShortcut.NewFromClipboard, appShortcutFor(KeyEvent.KEYCODE_N, ctrl = true, shift = true))
        assertEquals(AppShortcut.EditSnippet, appShortcutFor(KeyEvent.KEYCODE_E, ctrl = true, shift = false))
        assertEquals(AppShortcut.Export, appShortcutFor(KeyEvent.KEYCODE_E, ctrl = true, shift = true))
        assertEquals(AppShortcut.Import, appShortcutFor(KeyEvent.KEYCODE_I, ctrl = true, shift = true))
        assertEquals(AppShortcut.DeleteSnippet, appShortcutFor(KeyEvent.KEYCODE_DEL, ctrl = true, shift = false))
        assertEquals(AppShortcut.Undo, appShortcutFor(KeyEvent.KEYCODE_Z, ctrl = true, shift = false))
        assertEquals(AppShortcut.Settings, appShortcutFor(KeyEvent.KEYCODE_COMMA, ctrl = true, shift = false))
    }

    @Test
    fun plainKeys() {
        assertEquals(AppShortcut.DeleteSnippet, appShortcutFor(KeyEvent.KEYCODE_FORWARD_DEL, ctrl = false, shift = false))
        assertEquals(AppShortcut.ReturnToList, appShortcutFor(KeyEvent.KEYCODE_ESCAPE, ctrl = false, shift = false))
        assertNull(appShortcutFor(KeyEvent.KEYCODE_F, ctrl = false, shift = false))
        assertNull(appShortcutFor(KeyEvent.KEYCODE_DEL, ctrl = false, shift = false))
        assertNull(appShortcutFor(KeyEvent.KEYCODE_Z, ctrl = true, shift = true))
    }
}

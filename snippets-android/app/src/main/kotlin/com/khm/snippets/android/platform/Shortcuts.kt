package com.khm.snippets.android.platform

import android.content.Context
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.KeyboardShortcutInfo
import androidx.annotation.StringRes
import com.khm.snippets.android.R
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * The hardware-keyboard shortcuts the app handles itself (screens-library-editor.md §8). Tab,
 * the arrow keys and Enter on a focused row are focus traversal and clicks; text undo belongs
 * to the focused field.
 */
enum class AppShortcut(@param:StringRes val label: Int, val keyCode: Int, val modifiers: Int) {
    Search(R.string.shortcut_search, KeyEvent.KEYCODE_F, KeyEvent.META_CTRL_ON),
    NewSnippet(R.string.shortcut_new, KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON),
    NewFromClipboard(R.string.shortcut_new_from_clipboard, KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    EditSnippet(R.string.shortcut_edit, KeyEvent.KEYCODE_E, KeyEvent.META_CTRL_ON),
    DeleteSnippet(R.string.shortcut_delete, KeyEvent.KEYCODE_DEL, KeyEvent.META_CTRL_ON),
    ReturnToList(R.string.shortcut_return_to_list, KeyEvent.KEYCODE_ESCAPE, 0),
    Import(R.string.shortcut_import, KeyEvent.KEYCODE_I, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    Export(R.string.shortcut_export, KeyEvent.KEYCODE_E, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    Undo(R.string.shortcut_undo, KeyEvent.KEYCODE_Z, KeyEvent.META_CTRL_ON),
    Settings(R.string.shortcut_settings, KeyEvent.KEYCODE_COMMA, KeyEvent.META_CTRL_ON),
}

/**
 * The shortcut for a key press that no view consumed, or null. Forward Delete (without Ctrl)
 * also deletes.
 */
fun appShortcutFor(keyCode: Int, ctrl: Boolean, shift: Boolean): AppShortcut? {
    if (keyCode == KeyEvent.KEYCODE_FORWARD_DEL && !ctrl && !shift) return AppShortcut.DeleteSnippet
    val modifiers = (if (ctrl) KeyEvent.META_CTRL_ON else 0) or (if (shift) KeyEvent.META_SHIFT_ON else 0)
    return AppShortcut.entries.firstOrNull { it.keyCode == keyCode && it.modifiers == modifiers }
}

/** Carries shortcuts from the activity to whichever screen is showing. */
class ShortcutRouter {
    private val flow = MutableSharedFlow<AppShortcut>(extraBufferCapacity = 8)

    val shortcuts: SharedFlow<AppShortcut> = flow.asSharedFlow()

    /** True when a screen is listening and received the shortcut. */
    fun dispatch(shortcut: AppShortcut): Boolean = flow.subscriptionCount.value > 0 && flow.tryEmit(shortcut)
}

/**
 * The one group published to the system Keyboard Shortcuts Helper (Meta+/): the handled
 * shortcuts plus the keys the platform handles for us.
 */
fun keyboardShortcutGroup(context: Context): KeyboardShortcutGroup {
    val group = KeyboardShortcutGroup(context.getString(R.string.shortcut_group))
    fun add(@StringRes label: Int, keyCode: Int, modifiers: Int) {
        group.addItem(KeyboardShortcutInfo(context.getString(label), keyCode, modifiers))
    }
    add(R.string.shortcut_copy, KeyEvent.KEYCODE_ENTER, 0)
    AppShortcut.entries.forEach { add(it.label, it.keyCode, it.modifiers) }
    add(R.string.shortcut_delete, KeyEvent.KEYCODE_FORWARD_DEL, 0)
    add(R.string.shortcut_redo, KeyEvent.KEYCODE_Z, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON)
    add(R.string.shortcut_next_field, KeyEvent.KEYCODE_TAB, 0)
    add(R.string.shortcut_previous_field, KeyEvent.KEYCODE_TAB, KeyEvent.META_SHIFT_ON)
    add(R.string.shortcut_next_snippet, KeyEvent.KEYCODE_DPAD_DOWN, 0)
    add(R.string.shortcut_previous_snippet, KeyEvent.KEYCODE_DPAD_UP, 0)
    return group
}

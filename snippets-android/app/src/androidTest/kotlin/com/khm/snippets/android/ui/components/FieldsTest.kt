package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.text.TextRange
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.model.CodeFormat
import com.khm.snippets.android.ui.model.TagUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FieldsTest {
    @get:Rule
    val rule = createComposeRule()

    private val fieldTag = "secure.restore.field"
    private var code by mutableStateOf("")
    private var error by mutableStateOf<String?>(null)
    private var pastes = 0

    private fun setCodeField(initial: String = "", clipboard: String = "") {
        code = initial
        rule.setThemedContent {
            CodeField(
                value = code,
                onValueChange = { code = it },
                caption = "Recovery key",
                expectedLength = 27,
                onPasteClick = {
                    pastes++
                    code = CodeFormat.sanitize(clipboard)
                },
                tag = fieldTag,
                placeholder = "XXXX-XXXX-XXXX-…",
                errorText = error,
            )
        }
    }

    private fun editableText(): String =
        rule.onNodeWithTag(fieldTag).fetchSemanticsNode().config[SemanticsProperties.EditableText].text

    private fun selection(): TextRange =
        rule.onNodeWithTag(fieldTag).fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]

    @Test
    fun typingIsGroupedLiveAndStoredRaw() {
        setCodeField()
        rule.onNodeWithTag(fieldTag).performTextInput("7k2m9")
        assertEquals("7K2M9", code)
        assertEquals("7K2M-9", editableText())
        rule.onNodeWithTag(fieldTag).performTextInput("qxd")
        assertEquals("7K2M9QXD", code)
        assertEquals("7K2M-9QXD", editableText())
        rule.onNodeWithTag(fieldTag).performTextInput("4")
        assertEquals("7K2M-9QXD-4", editableText())
    }

    @Test
    fun lowerCaseSpacesAndStrayHyphensAreAccepted() {
        setCodeField()
        rule.onNodeWithTag(fieldTag).performTextInput("7k2m - 9qxd--4f tr")
        assertEquals("7K2M9QXD4FTR", code)
        assertEquals("7K2M-9QXD-4FTR", editableText())
    }

    @Test
    fun counterRunsUntilTheValueIsComplete() {
        setCodeField()
        rule.onNodeWithTag("$fieldTag.counter", useUnmergedTree = true).assertTextEquals("0 of 27 characters")
        rule.onNodeWithTag(fieldTag).performTextInput("7K2M9QXD4FTRHV3NP8WC6Y")
        rule.onNodeWithTag("$fieldTag.counter", useUnmergedTree = true).assertTextEquals("22 of 27 characters")
        rule.onNodeWithTag(fieldTag).performTextInput("JAB5G")
        assertEquals(27, code.length)
        rule.onNodeWithTag("$fieldTag.counter", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun pasteButtonReplacesTheValueAndPutsTheCaretAtTheEnd() {
        setCodeField(initial = "ZZ", clipboard = "7k2m-9qxd-4ftr-hv3n-p8wc-6yja-b5g\n")
        rule.onNodeWithTag("$fieldTag.paste").assertContentDescriptionEquals("Paste").performClick()
        assertEquals(1, pastes)
        assertEquals("7K2M9QXD4FTRHV3NP8WC6YJAB5G", code)
        assertEquals("7K2M-9QXD-4FTR-HV3N-P8WC-6YJA-B5G", editableText())
        rule.onNodeWithTag(fieldTag).performTextInput("X")
        assertEquals("7K2M9QXD4FTRHV3NP8WC6YJAB5GX", code)
    }

    @Test
    fun pastedTextTypedIntoTheFieldIsNormalisedToo() {
        setCodeField()
        rule.onNodeWithTag(fieldTag).performTextReplacement("7k2m-9qxd-4ftr")
        assertEquals("7K2M9QXD4FTR", code)
        // The caret is behind the last symbol (the selection is reported in raw symbols).
        assertEquals(TextRange(12), selection())
        assertEquals("7K2M-9QXD-4FTR", editableText())
    }

    @Test
    fun caretStaysBehindTheSymbolItFollowed() {
        setCodeField(initial = "7K2M9QXD")
        // Put the caret behind "2" and type. Offsets are in raw symbols.
        rule.onNodeWithTag(fieldTag).requestFocus()
        rule.onNodeWithTag(fieldTag).performTextInputSelection(TextRange(3))
        rule.onNodeWithTag(fieldTag).performTextInput("a")
        assertEquals("7K2AM9QXD", code)
        assertEquals("7K2A-M9QX-D", editableText())
        assertEquals(TextRange(4), selection())
        // A stray hyphen changes nothing and does not move the caret.
        rule.onNodeWithTag(fieldTag).performTextInput("-")
        assertEquals("7K2AM9QXD", code)
        assertEquals(TextRange(4), selection())
        // Typing on continues behind the separator.
        rule.onNodeWithTag(fieldTag).performTextInput("b")
        assertEquals("7K2ABM9QXD", code)
        assertEquals("7K2A-BM9Q-XD", editableText())
        assertEquals(TextRange(5), selection())
        // In the grouped text that caret sits behind the separator and the new symbol.
        assertEquals(6, CodeFormat.rawToGroupedOffset(5, code.length))
    }

    @Test
    fun errorReplacesTheCounterAndKeepsTheInput() {
        setCodeField(initial = "7K2M9QXD")
        error = "That recovery key has a typo in it."
        rule.onNodeWithTag("$fieldTag.message", useUnmergedTree = true).assertTextEquals("That recovery key has a typo in it.")
        rule.onNodeWithTag("$fieldTag.counter", useUnmergedTree = true).assertDoesNotExist()
        assertEquals("7K2M-9QXD", editableText())
        val config = rule.onNodeWithTag(fieldTag).fetchSemanticsNode().config
        assertEquals("That recovery key has a typo in it.", config[SemanticsProperties.Error])
    }

    @Test
    fun captionLabelsTheField() {
        setCodeField()
        rule.onNodeWithContentDescription("Recovery key").assertExists()
        val caption = rule.onNodeWithTag("$fieldTag.caption", useUnmergedTree = true).fetchSemanticsNode().config
        assertNull(caption.getOrNull(SemanticsProperties.Text))
    }

    @Test
    fun labeledFieldShowsSupportingTextThenError() {
        var value by mutableStateOf("")
        var fieldError by mutableStateOf<String?>(null)
        rule.setThemedContent {
            LabeledField(
                value = value,
                onValueChange = { value = it },
                caption = "Repository",
                tag = "git.repository",
                supportingText = "The address of the repository.",
                errorText = fieldError,
            )
        }
        rule.onNodeWithTag("git.repository.message", useUnmergedTree = true).assertTextEquals("The address of the repository.")
        rule.onNodeWithTag("git.repository").performTextInput("ftp://x")
        assertEquals("ftp://x", value)
        fieldError = "Enter an https:// or ssh address."
        rule.onNodeWithTag("git.repository.message", useUnmergedTree = true).assertTextEquals("Enter an https:// or ssh address.")
        assertEquals("ftp://x", value)
    }

    @Test
    fun passwordFieldTogglesVisibility() {
        var visible by mutableStateOf(false)
        rule.setThemedContent {
            PasswordField(
                value = "hunter2",
                onValueChange = {},
                caption = "Backup password",
                passwordVisible = visible,
                onPasswordVisibleChange = { visible = it },
                tag = "backup.password",
            )
        }
        val field = rule.onNodeWithTag("backup.password")
        assertEquals("•••••••", field.fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
        rule.onNodeWithTag("backup.password.visibility")
            .assertContentDescriptionEquals("Show password")
            .performClick()
        assertTrue(visible)
        assertEquals("hunter2", field.fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
        rule.onNodeWithTag("backup.password.visibility").assertContentDescriptionEquals("Hide password")
    }

    @Test
    fun keywordFieldShowsItsWarningAndDescribesIt() {
        rule.setThemedContent {
            KeywordField(
                value = "notes",
                onValueChange = {},
                caption = "Keyword",
                message = "\\notes is already used by Meeting room.",
                messageIsWarning = true,
            )
        }
        rule.onNodeWithTag("editor.keyword.message", useUnmergedTree = true).assertTextEquals("\\notes is already used by Meeting room.")
        rule.onNodeWithTag("editor.keyword.warning-icon", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("editor.keyword").assertContentDescriptionEquals("Keyword, warning: \\notes is already used by Meeting room.")
        // With focus the message makes room for the help strip.
        rule.onNodeWithTag("editor.keyword").requestFocus()
        rule.onNodeWithTag("editor.keyword.message", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("editor.keyword.warning-icon", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun tagFieldReportsEditsCommitAndRemoval() {
        val events = ArrayList<String>()
        var input by mutableStateOf("")
        rule.setThemedContent {
            Column {
                TagField(
                    tags = listOf(TagUi("work", "work"), TagUi("Notes", "notes")),
                    input = input,
                    onInputChange = {
                        input = it
                        events += "input:$it"
                    },
                    onCommitInput = { events += "commit" },
                    onRemoveTag = { events += "remove:${it.folded}" },
                    onRemoveLastTag = { events += "remove-last" },
                    caption = "Tags",
                )
            }
        }
        rule.onNodeWithTag("editor.tags").assertExists()
        rule.onNodeWithTag("editor.tag.work").assertExists()
        rule.onNodeWithTag("editor.tags.input").performTextInput("links")
        rule.onNodeWithTag("editor.tags.input").performImeAction()
        rule.onNodeWithTag("editor.tag.notes.remove").assertContentDescriptionEquals("Remove tag Notes").performClick()
        assertEquals(listOf("input:links", "commit", "remove:notes"), events)
    }

    @Test
    fun switchRowTogglesAsOneNode() {
        var checked by mutableStateOf(false)
        rule.setThemedContent {
            SwitchRow(
                title = "Enabled",
                checked = checked,
                onCheckedChange = { checked = it },
                tag = "editor.enabled",
                supportingText = "Allow this keyword to expand on Mac.",
                clickLabel = "Controls whether this keyword can expand on Mac.",
            )
        }
        val row = rule.onNodeWithTag("editor.enabled")
        row.assertIsOff()
        row.performClick()
        assertTrue(checked)
        row.assertIsOn()
        val switch = rule.onNodeWithTag("editor.enabled.switch", useUnmergedTree = true).fetchSemanticsNode().config
        assertNull(switch.getOrNull(SemanticsProperties.ToggleableState))
        assertEquals(ToggleableState.On, row.fetchSemanticsNode().config[SemanticsProperties.ToggleableState])
    }
}

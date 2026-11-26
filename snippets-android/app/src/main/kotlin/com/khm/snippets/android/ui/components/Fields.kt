package com.khm.snippets.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CodeFormat
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

@Composable
private fun fieldColors(): TextFieldColors {
    val colors = MaterialTheme.colorScheme
    return OutlinedTextFieldDefaults.colors(
        focusedContainerColor = colors.surfaceContainerHigh,
        unfocusedContainerColor = colors.surfaceContainerHigh,
        disabledContainerColor = colors.surfaceContainerHigh,
        errorContainerColor = colors.surfaceContainerHigh,
        focusedBorderColor = colors.primary,
        unfocusedBorderColor = colors.outlineVariant,
        errorBorderColor = colors.error,
        focusedTextColor = colors.onSurface,
        unfocusedTextColor = colors.onSurface,
        errorTextColor = colors.onSurface,
        focusedPlaceholderColor = colors.onSurfaceVariant,
        unfocusedPlaceholderColor = colors.onSurfaceVariant,
        errorPlaceholderColor = colors.onSurfaceVariant,
        unfocusedSupportingTextColor = colors.onSurfaceVariant,
        focusedSupportingTextColor = colors.onSurfaceVariant,
        errorSupportingTextColor = colors.error,
    )
}

/** The caption above a field. Its text reaches accessibility as the field's description. */
@Composable
private fun FieldCaption(caption: String, tag: String?) {
    Text(
        text = caption,
        modifier = Modifier
            .padding(bottom = Dimens.fieldCaptionGap)
            .clearAndSetSemantics { if (tag != null) testTag = tag + TestTags.Field.CAPTION },
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.labelLarge,
    )
}

/** Supporting or error text under a field; an error is an assertive live region. */
@Composable
private fun FieldMessage(
    text: String,
    isError: Boolean,
    tag: String?,
    color: Color = Color.Unspecified,
    suffix: String = TestTags.Field.MESSAGE,
) {
    Text(
        text = text,
        modifier = Modifier
            .then(if (tag != null) Modifier.testTag(tag + suffix) else Modifier)
            .then(if (isError) Modifier.semantics { liveRegion = LiveRegionMode.Assertive } else Modifier),
        color = color,
    )
}

/** The decoration every field shares: surface, border, placeholder, icons, message. */
@Composable
private fun FieldDecoration(
    value: String,
    innerTextField: @Composable () -> Unit,
    enabled: Boolean,
    readOnly: Boolean,
    singleLine: Boolean,
    visualTransformation: VisualTransformation,
    interactionSource: MutableInteractionSource,
    textStyle: TextStyle,
    placeholder: String?,
    message: (@Composable () -> Unit)?,
    isError: Boolean,
    prefix: (@Composable () -> Unit)?,
    trailing: (@Composable () -> Unit)?,
) {
    val colors = fieldColors()
    val errorTint = MaterialTheme.colorScheme.error
    val trailingIcon: (@Composable () -> Unit)? = if (isError || trailing != null) {
        {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (isError) {
                    Box(
                        modifier = if (trailing == null) Modifier.size(Dimens.touchTarget) else Modifier.padding(start = Spacing.m),
                        contentAlignment = Alignment.Center,
                    ) {
                        Glyph(SnippetsIcon.Error, contentDescription = null, tint = errorTint)
                    }
                }
                trailing?.invoke()
            }
        }
    } else {
        null
    }
    OutlinedTextFieldDefaults.DecorationBox(
        value = value,
        innerTextField = innerTextField,
        enabled = enabled,
        singleLine = singleLine,
        visualTransformation = visualTransformation,
        interactionSource = interactionSource,
        isError = isError,
        placeholder = placeholder?.let {
            {
                // The placeholder colour comes from the decoration, not from the input style.
                Text(
                    text = it,
                    style = textStyle.copy(color = Color.Unspecified),
                    maxLines = if (singleLine) 1 else Int.MAX_VALUE,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        },
        trailingIcon = trailingIcon,
        prefix = prefix,
        supportingText = message,
        colors = colors,
        container = {
            OutlinedTextFieldDefaults.Container(
                enabled = enabled,
                isError = isError,
                interactionSource = interactionSource,
                colors = colors,
                shape = MaterialTheme.shapes.medium,
                focusedBorderThickness = if (readOnly) 0.dp else Dimens.borderThick,
                // An error keeps its 2 dp border without focus; a read-only value has none.
                unfocusedBorderThickness = when {
                    readOnly -> 0.dp
                    isError -> Dimens.borderThick
                    else -> Dimens.borderThin
                },
            )
        },
    )
}

/**
 * A field with its caption above it (components.md §11.1): no floating label, a
 * `surfaceContainerHigh` surface of shape medium, a 1 dp `outlineVariant` border that becomes
 * 2 dp `primary` with focus and 2 dp `error` on an error.
 *
 * An error replaces the supporting text, adds a trailing error icon and is announced
 * assertively; the field keeps its input. Validate on submit and on blur after an edit, not
 * while the user is still typing.
 *
 * @param tag Test tag of the field; the caption and message use `<tag>.caption`, `<tag>.message`.
 * @param supportingColor Overrides the colour of [supportingText] (a keyword warning).
 * @param readOnly Shows a read-only value: same surface, no border.
 * @param description Accessibility description of the field; the caption by default.
 */
@Composable
fun LabeledField(
    value: String,
    onValueChange: (String) -> Unit,
    caption: String,
    modifier: Modifier = Modifier,
    tag: String? = null,
    placeholder: String? = null,
    supportingText: String? = null,
    errorText: String? = null,
    supportingColor: Color = Color.Unspecified,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    singleLine: Boolean = true,
    minLines: Int = 1,
    minHeight: Dp = Dimens.fieldMinHeight,
    textStyle: TextStyle = MaterialTheme.typography.bodyLarge,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    description: String? = null,
    interactionSource: MutableInteractionSource? = null,
    prefix: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    LabeledFieldFrame(
        text = value, caption = caption, modifier = modifier, tag = tag, placeholder = placeholder,
        supportingText = supportingText, errorText = errorText, supportingColor = supportingColor,
        enabled = enabled, readOnly = readOnly, singleLine = singleLine, minHeight = minHeight,
        textStyle = textStyle, visualTransformation = visualTransformation, description = description,
        interactionSource = interactionSource, prefix = prefix, trailing = trailing,
    ) { fieldModifier, resolvedStyle, cursor, source, decorationBox ->
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = fieldModifier,
            enabled = enabled,
            readOnly = readOnly,
            textStyle = resolvedStyle,
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            singleLine = singleLine,
            minLines = minLines,
            visualTransformation = visualTransformation,
            interactionSource = source,
            cursorBrush = cursor,
            decorationBox = decorationBox,
        )
    }
}

/**
 * [LabeledField] on a [TextFieldValue], for a field whose caller moves the caret (the keyword
 * field after a completion).
 */
@Composable
fun LabeledField(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    caption: String,
    modifier: Modifier = Modifier,
    tag: String? = null,
    placeholder: String? = null,
    supportingText: String? = null,
    errorText: String? = null,
    supportingColor: Color = Color.Unspecified,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    singleLine: Boolean = true,
    minLines: Int = 1,
    minHeight: Dp = Dimens.fieldMinHeight,
    textStyle: TextStyle = MaterialTheme.typography.bodyLarge,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    description: String? = null,
    interactionSource: MutableInteractionSource? = null,
    prefix: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    LabeledFieldFrame(
        text = value.text, caption = caption, modifier = modifier, tag = tag, placeholder = placeholder,
        supportingText = supportingText, errorText = errorText, supportingColor = supportingColor,
        enabled = enabled, readOnly = readOnly, singleLine = singleLine, minHeight = minHeight,
        textStyle = textStyle, visualTransformation = visualTransformation, description = description,
        interactionSource = interactionSource, prefix = prefix, trailing = trailing,
    ) { fieldModifier, resolvedStyle, cursor, source, decorationBox ->
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = fieldModifier,
            enabled = enabled,
            readOnly = readOnly,
            textStyle = resolvedStyle,
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            singleLine = singleLine,
            minLines = minLines,
            visualTransformation = visualTransformation,
            interactionSource = source,
            cursorBrush = cursor,
            decorationBox = decorationBox,
        )
    }
}

/** What both [LabeledField] overloads share: caption, semantics, decoration. */
@Composable
private fun LabeledFieldFrame(
    text: String,
    caption: String,
    modifier: Modifier,
    tag: String?,
    placeholder: String?,
    supportingText: String?,
    errorText: String?,
    supportingColor: Color,
    enabled: Boolean,
    readOnly: Boolean,
    singleLine: Boolean,
    minHeight: Dp,
    textStyle: TextStyle,
    visualTransformation: VisualTransformation,
    description: String?,
    interactionSource: MutableInteractionSource?,
    prefix: (@Composable () -> Unit)?,
    trailing: (@Composable () -> Unit)?,
    field: @Composable (
        fieldModifier: Modifier,
        resolvedStyle: TextStyle,
        cursor: SolidColor,
        source: MutableInteractionSource,
        decorationBox: @Composable (innerTextField: @Composable () -> Unit) -> Unit,
    ) -> Unit,
) {
    val source = interactionSource ?: remember { MutableInteractionSource() }
    val colors = MaterialTheme.colorScheme
    val isError = errorText != null
    val message = errorText ?: supportingText
    val resolvedStyle = textStyle.copy(color = colors.onSurface)
    val fieldDescription = description ?: caption
    Column(modifier = modifier) {
        FieldCaption(caption = caption, tag = tag)
        field(
            Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = minHeight)
                .then(if (tag != null) Modifier.testTag(tag) else Modifier)
                .semantics {
                    contentDescription = fieldDescription
                    if (errorText != null) error(errorText)
                },
            resolvedStyle,
            SolidColor(if (isError) colors.error else colors.primary),
            source,
        ) { innerTextField ->
            FieldDecoration(
                value = text,
                innerTextField = innerTextField,
                enabled = enabled,
                readOnly = readOnly,
                singleLine = singleLine,
                visualTransformation = visualTransformation,
                interactionSource = source,
                textStyle = resolvedStyle,
                placeholder = placeholder,
                message = message?.let {
                    { FieldMessage(text = it, isError = isError, tag = tag, color = if (isError) Color.Unspecified else supportingColor) }
                },
                isError = isError,
                prefix = prefix,
                trailing = trailing,
            )
        }
    }
}

/**
 * The keyword field (components.md §11.4): monospaced, with the display-only `\` prefix and the
 * placeholder `sig`.
 *
 * [message] is shown as supporting text whenever the field is not focused. At warning level it
 * is drawn in `warning` with a decorative trailing warning icon, and the field is described as
 * `Keyword, warning: …`. While the field has focus [helpWhileFocused] takes the message's place
 * (suggestion chips or the `Existing ·` line).
 *
 * The caller sanitises the value on every change.
 */
@Composable
fun KeywordField(
    value: String,
    onValueChange: (String) -> Unit,
    caption: String,
    modifier: Modifier = Modifier,
    tag: String = "editor.keyword",
    message: String? = null,
    messageIsWarning: Boolean = false,
    enabled: Boolean = true,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    helpWhileFocused: (@Composable () -> Unit)? = null,
) {
    KeywordFieldFrame(caption, modifier, tag, message, messageIsWarning, helpWhileFocused) { look ->
        LabeledField(
            value = value,
            onValueChange = onValueChange,
            caption = caption,
            tag = tag,
            placeholder = look.placeholder,
            supportingText = look.supportingText,
            supportingColor = look.supportingColor,
            enabled = enabled,
            textStyle = look.textStyle,
            keyboardOptions = KeywordKeyboardOptions,
            keyboardActions = keyboardActions,
            description = look.description,
            interactionSource = look.interactionSource,
            prefix = look.prefix,
            trailing = look.trailing,
        )
    }
}

/** [KeywordField] on a [TextFieldValue], so the caller can put the caret after a completion. */
@Composable
fun KeywordField(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    caption: String,
    modifier: Modifier = Modifier,
    tag: String = "editor.keyword",
    message: String? = null,
    messageIsWarning: Boolean = false,
    enabled: Boolean = true,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    helpWhileFocused: (@Composable () -> Unit)? = null,
) {
    KeywordFieldFrame(caption, modifier, tag, message, messageIsWarning, helpWhileFocused) { look ->
        LabeledField(
            value = value,
            onValueChange = onValueChange,
            caption = caption,
            tag = tag,
            placeholder = look.placeholder,
            supportingText = look.supportingText,
            supportingColor = look.supportingColor,
            enabled = enabled,
            textStyle = look.textStyle,
            keyboardOptions = KeywordKeyboardOptions,
            keyboardActions = keyboardActions,
            description = look.description,
            interactionSource = look.interactionSource,
            prefix = look.prefix,
            trailing = look.trailing,
        )
    }
}

private val KeywordKeyboardOptions = KeyboardOptions(
    capitalization = KeyboardCapitalization.None,
    autoCorrectEnabled = false,
    keyboardType = KeyboardType.Ascii,
    imeAction = ImeAction.Next,
)

/** How the keyword field looks in its current focus and message state. */
private class KeywordFieldLook(
    val placeholder: String,
    val supportingText: String?,
    val supportingColor: Color,
    val textStyle: TextStyle,
    val description: String?,
    val interactionSource: MutableInteractionSource,
    val prefix: @Composable () -> Unit,
    val trailing: (@Composable () -> Unit)?,
)

@Composable
private fun KeywordFieldFrame(
    caption: String,
    modifier: Modifier,
    tag: String,
    message: String?,
    messageIsWarning: Boolean,
    helpWhileFocused: (@Composable () -> Unit)?,
    field: @Composable (KeywordFieldLook) -> Unit,
) {
    val warning = SnippetsTheme.colors.warning
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val showMessage = message != null && !focused
    val showWarning = showMessage && messageIsWarning
    val tokenStyle = SnippetsTheme.typography.monoToken
    val prefixColor = MaterialTheme.colorScheme.onSurfaceVariant
    val prefixText = stringResource(R.string.field_keyword_prefix)
    Column(modifier = modifier) {
        field(
            KeywordFieldLook(
                placeholder = stringResource(R.string.field_keyword_placeholder),
                supportingText = if (showMessage) message else null,
                supportingColor = if (showWarning) warning else Color.Unspecified,
                textStyle = tokenStyle,
                description = if (message != null && messageIsWarning) {
                    stringResource(R.string.field_keyword_warning_description, message)
                } else {
                    caption
                },
                interactionSource = interactionSource,
                prefix = { Text(text = prefixText, color = prefixColor, style = tokenStyle) },
                trailing = if (showWarning) {
                    {
                        Box(modifier = Modifier.size(Dimens.touchTarget), contentAlignment = Alignment.Center) {
                            Glyph(
                                icon = SnippetsIcon.Warning,
                                contentDescription = null,
                                modifier = Modifier.testTag(tag + TestTags.Field.WARNING_ICON),
                                tint = warning,
                            )
                        }
                    }
                } else {
                    null
                },
            ),
        )
        if (focused && helpWhileFocused != null) {
            Box(modifier = Modifier.padding(top = Dimens.fieldCaptionGap)) {
                helpWhileFocused()
            }
        }
    }
}

/**
 * A password field (components.md §11.4) with the show / hide toggle.
 *
 * @param onPasteClick Adds a Paste button (the access token field); read the clipboard there.
 * @param isNewPassword Autofill content type: a new password, or an existing one.
 */
@Composable
fun PasswordField(
    value: String,
    onValueChange: (String) -> Unit,
    caption: String,
    passwordVisible: Boolean,
    onPasswordVisibleChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    placeholder: String? = null,
    supportingText: String? = null,
    errorText: String? = null,
    enabled: Boolean = true,
    isNewPassword: Boolean = false,
    imeAction: ImeAction = ImeAction.Done,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    onPasteClick: (() -> Unit)? = null,
) {
    LabeledField(
        value = value,
        onValueChange = onValueChange,
        caption = caption,
        modifier = modifier.semantics {
            contentType = if (isNewPassword) ContentType.NewPassword else ContentType.Password
        },
        tag = tag,
        placeholder = placeholder,
        supportingText = supportingText,
        errorText = errorText,
        enabled = enabled,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Password,
            imeAction = imeAction,
        ),
        keyboardActions = keyboardActions,
        visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
        trailing = {
            Row {
                if (onPasteClick != null) {
                    SnippetsIconButton(
                        icon = SnippetsIcon.ContentPaste,
                        contentDescription = stringResource(R.string.action_paste),
                        onClick = onPasteClick,
                        tag = tag?.let { it + TestTags.Field.PASTE },
                    )
                }
                SnippetsIconButton(
                    icon = if (passwordVisible) SnippetsIcon.VisibilityOff else SnippetsIcon.Visibility,
                    contentDescription = stringResource(
                        if (passwordVisible) R.string.field_password_hide else R.string.field_password_show,
                    ),
                    onClick = { onPasswordVisibleChange(!passwordVisible) },
                    tag = tag?.let { it + TestTags.Field.VISIBILITY },
                )
            }
        },
    )
}

/** Draws raw symbols in groups: a hyphen between every group of [groupSize]. */
internal class GroupingTransformation(private val groupSize: Int) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val raw = text.text
        val mapping = object : OffsetMapping {
            override fun originalToTransformed(offset: Int): Int =
                CodeFormat.rawToGroupedOffset(offset, raw.length, groupSize)

            override fun transformedToOriginal(offset: Int): Int =
                CodeFormat.groupedToRawOffset(offset, raw.length, groupSize)
        }
        return TransformedText(AnnotatedString(CodeFormat.grouped(raw, groupSize)), mapping)
    }

    override fun equals(other: Any?): Boolean = other is GroupingTransformation && other.groupSize == groupSize

    override fun hashCode(): Int = groupSize
}

/**
 * The field for a recovery key, recovery code, account key or kit code (components.md §11.4):
 * one monospaced field that groups the symbols as they are typed.
 *
 * [value] and [onValueChange] carry the raw symbols. Lower case, spaces and stray hyphens are
 * accepted and normalised; the caret stays behind the symbol it followed. Under the field a
 * counter (`22 of 27 characters`) runs until the value is complete; [errorText] replaces it.
 * The keyboard is asked not to learn from the input.
 *
 * @param expectedLength Number of symbols in a complete value.
 * @param onPasteClick The Paste button: read the clipboard there (only then) and pass the text
 *   through [CodeFormat.sanitize]. See [rememberClipboardPaste].
 */
@Composable
fun CodeField(
    value: String,
    onValueChange: (String) -> Unit,
    caption: String,
    expectedLength: Int,
    onPasteClick: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    placeholder: String? = null,
    errorText: String? = null,
    groupSize: Int = CodeFormat.DEFAULT_GROUP_SIZE,
    enabled: Boolean = true,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    val colors = MaterialTheme.colorScheme
    val interactionSource = remember { MutableInteractionSource() }
    val transformation = remember(groupSize) { GroupingTransformation(groupSize) }
    val isError = errorText != null
    val textStyle = SnippetsTheme.typography.monoField.copy(color = colors.onSurface)

    var selection by remember { mutableStateOf(TextRange(value.length)) }
    var lastSeen by remember { mutableStateOf(value) }
    if (lastSeen != value) {
        // Changed from outside (Paste, a reset): the caret goes to the end.
        lastSeen = value
        selection = TextRange(value.length)
    }
    val fieldValue = TextFieldValue(
        text = value,
        selection = TextRange(selection.start.coerceIn(0, value.length), selection.end.coerceIn(0, value.length)),
    )
    val counter = if (!isError && value.length < expectedLength) {
        pluralStringResource(R.plurals.field_code_counter, expectedLength, value.length, expectedLength)
    } else {
        null
    }
    Column(modifier = modifier) {
        FieldCaption(caption = caption, tag = tag)
        SecretTextInput {
            BasicTextField(
                value = fieldValue,
                onValueChange = { edited ->
                    val (raw, caret) = CodeFormat.sanitizeEdit(edited.text, edited.selection.end)
                    selection = if (raw == edited.text) edited.selection else TextRange(caret)
                    lastSeen = raw
                    if (raw != value) onValueChange(raw)
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = Dimens.fieldMinHeight)
                    .then(if (tag != null) Modifier.testTag(tag) else Modifier)
                    .semantics {
                        contentDescription = caption
                        if (errorText != null) error(errorText)
                    },
                enabled = enabled,
                textStyle = textStyle,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Characters,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = keyboardActions,
                singleLine = true,
                visualTransformation = transformation,
                interactionSource = interactionSource,
                cursorBrush = SolidColor(if (isError) colors.error else colors.primary),
                decorationBox = { innerTextField ->
                    FieldDecoration(
                        value = value,
                        innerTextField = innerTextField,
                        enabled = enabled,
                        readOnly = false,
                        singleLine = true,
                        visualTransformation = transformation,
                        interactionSource = interactionSource,
                        textStyle = textStyle,
                        placeholder = placeholder,
                        message = when {
                            errorText != null -> {
                                { FieldMessage(text = errorText, isError = true, tag = tag) }
                            }
                            counter != null -> {
                                { FieldMessage(text = counter, isError = false, tag = tag, suffix = TestTags.Field.COUNTER) }
                            }
                            else -> null
                        },
                        isError = isError,
                        prefix = null,
                        trailing = {
                            SnippetsIconButton(
                                icon = SnippetsIcon.ContentPaste,
                                contentDescription = stringResource(R.string.action_paste),
                                onClick = onPasteClick,
                                tag = tag?.let { it + TestTags.Field.PASTE },
                                enabled = enabled,
                            )
                        },
                    )
                },
            )
        }
    }
}

/**
 * The tag field (components.md §11.4): the field surface holding one removable chip per tag and
 * then the text input. Tapping empty space focuses the input.
 *
 * The field reports raw events; the caller owns the tag rules:
 * - [onInputChange]: every edit of the pending text. Text that contains a comma or a line break
 *   (typed or pasted) is to be split into tags there.
 * - [onCommitInput]: IME `Done`, Enter, or focus leaving the input: commit the pending text.
 * - [onRemoveLastTag]: Backspace in an empty input.
 * - [onRemoveTag]: the `×` of a chip.
 * - [onEnterKey]: a hardware Enter. By default it commits; the editor accepts the first
 *   completion there when one exists.
 *
 * @param tag Test tag of the container; the input is `<tag>.input`, chips are
 *   `editor.tag.<foldedTag>` with `.remove`.
 * @param inputModifier Added to the text input, for a focus requester of the screen.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TagField(
    tags: List<TagUi>,
    input: String,
    onInputChange: (String) -> Unit,
    onCommitInput: () -> Unit,
    onRemoveTag: (TagUi) -> Unit,
    onRemoveLastTag: () -> Unit,
    caption: String,
    modifier: Modifier = Modifier,
    tag: String = "editor.tags",
    enabled: Boolean = true,
    inputModifier: Modifier = Modifier,
    onEnterKey: () -> Unit = onCommitInput,
) {
    val colors = MaterialTheme.colorScheme
    val focusRequester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    val textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface)
    val shape = MaterialTheme.shapes.medium
    Column(modifier = modifier) {
        FieldCaption(caption = caption, tag = tag)
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = Dimens.fieldMinHeight)
                .background(colors.surfaceContainerHigh, shape)
                .border(
                    width = if (focused) Dimens.borderThick else Dimens.borderThin,
                    color = if (focused) colors.primary else colors.outlineVariant,
                    shape = shape,
                )
                .pointerInput(enabled) {
                    if (enabled) detectTapGestures { focusRequester.requestFocus() }
                }
                .testTag(tag)
                .padding(Spacing.s),
            horizontalArrangement = Arrangement.spacedBy(Dimens.chipGap),
            verticalArrangement = Arrangement.spacedBy(Dimens.chipGap),
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            tags.forEach { item ->
                EditableTagChip(tag = item, onRemove = { onRemoveTag(item) }, enabled = enabled)
            }
            BasicTextField(
                value = input,
                onValueChange = onInputChange,
                modifier = Modifier
                    .weight(1f)
                    .widthIn(min = Dimens.tagFieldInputMinWidth)
                    .heightIn(min = Dimens.inputChipHeight)
                    .focusRequester(focusRequester)
                    .onFocusChanged { state ->
                        if (focused && !state.isFocused) onCommitInput()
                        focused = state.isFocused
                    }
                    .onPreviewKeyEvent { event ->
                        when {
                            event.key == Key.Backspace && input.isEmpty() -> {
                                if (event.type == KeyEventType.KeyDown) onRemoveLastTag()
                                true
                            }
                            event.key == Key.Enter || event.key == Key.NumPadEnter -> {
                                if (event.type == KeyEventType.KeyUp) onEnterKey()
                                true
                            }
                            else -> false
                        }
                    }
                    .testTag(tag + TestTags.Field.INPUT)
                    .semantics { contentDescription = caption }
                    .then(inputModifier),
                enabled = enabled,
                textStyle = textStyle,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Text,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { onCommitInput() }),
                singleLine = true,
                cursorBrush = SolidColor(colors.primary),
                decorationBox = { innerTextField ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (tags.isEmpty() && input.isEmpty()) {
                            Text(
                                text = stringResource(R.string.field_tags_placeholder),
                                style = textStyle,
                                color = colors.onSurfaceVariant,
                                maxLines = 1,
                            )
                        }
                        innerTextField()
                    }
                },
            )
        }
    }
}

/**
 * A tag inside the tag field: the tag's fill and text colour, and a remove button whose 18 dp
 * icon sits in a 48 dp touch target that overlaps the chip, not its neighbour.
 */
@Composable
private fun EditableTagChip(
    tag: TagUi,
    onRemove: () -> Unit,
    enabled: Boolean,
) {
    val tagColor = tagColorOf(tag)
    val chipTag = TestTags.editorTag(tag.folded)
    // A plain background, not a clipping Surface: the remove button's 48 dp touch target reaches
    // beyond the 32 dp chip.
    Row(
        modifier = Modifier
            .heightIn(min = Dimens.inputChipHeight)
            .background(tagColor.fill, MaterialTheme.shapes.small)
            .testTag(chipTag)
            .padding(start = Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(LocalContentColor provides tagColor.text) {
            Text(
                text = tag.name,
                modifier = Modifier.weight(1f, fill = false),
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val description = stringResource(R.string.field_tag_remove, tag.name)
            Box(
                modifier = Modifier
                    .size(Dimens.inputChipHeight)
                    .clip(CircleShape)
                    .clickable(enabled = enabled, role = Role.Button, onClick = onRemove)
                    .semantics { contentDescription = description }
                    .testTag(chipTag + TestTags.Field.REMOVE),
                contentAlignment = Alignment.Center,
            ) {
                Glyph(SnippetsIcon.Close, contentDescription = null, size = Dimens.iconSmall)
            }
        }
    }
}

/**
 * A switch row (components.md §11.4): the whole row toggles; the `Switch` itself has no
 * semantics of its own. Perform [SnippetsHaptics.toggle] in [onCheckedChange].
 *
 * @param clickLabel What a screen reader says the double-tap does.
 */
@Composable
fun SwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    supportingText: String? = null,
    enabled: Boolean = true,
    clickLabel: String? = null,
    icon: SnippetsIcon? = null,
) {
    val colors = MaterialTheme.colorScheme
    ListItem(
        headlineContent = {
            Text(
                text = title,
                modifier = if (tag != null) Modifier.testTag(tag + TestTags.Settings.TITLE) else Modifier,
                color = if (enabled) colors.onSurface else colors.onSurface.copy(alpha = DISABLED_CONTENT_ALPHA),
            )
        },
        modifier = modifier
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
            .then(if (clickLabel != null) Modifier.semantics { onClick(label = clickLabel, action = null) } else Modifier)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier),
        supportingContent = supportingText?.let {
            {
                Text(
                    text = it,
                    modifier = if (tag != null) Modifier.testTag(tag + TestTags.Settings.DETAIL) else Modifier,
                    color = colors.onSurfaceVariant,
                )
            }
        },
        leadingContent = icon?.let { { Glyph(it, contentDescription = null, tint = colors.onSurfaceVariant) } },
        trailingContent = {
            Switch(
                checked = checked,
                onCheckedChange = null,
                modifier = Modifier.clearAndSetSemantics { if (tag != null) testTag = tag + TestTags.Settings.SWITCH },
                enabled = enabled,
            )
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

/** M3 disabled content opacity; only for controls that are really disabled. */
internal const val DISABLED_CONTENT_ALPHA = 0.38f

@Preview(name = "Fields, light", widthDp = 375)
@Composable
private fun FieldsPreviewLight() = PreviewSurface(darkTheme = false) { FieldsPreviewContent() }

@Preview(name = "Fields, dark", widthDp = 375)
@Composable
private fun FieldsPreviewDark() = PreviewSurface(darkTheme = true) { FieldsPreviewContent() }

@Composable
private fun FieldsPreviewContent() {
    Column(verticalArrangement = Arrangement.spacedBy(Dimens.fieldGap)) {
        LabeledField(value = "Meeting notes", onValueChange = {}, caption = "Name")
        LabeledField(value = "", onValueChange = {}, caption = "Repository", errorText = "Enter the repository address.")
        KeywordField(value = "notes", onValueChange = {}, caption = "Keyword", message = "\\notes is already used by Meeting room.", messageIsWarning = true)
        TagField(
            tags = listOf(TagUi("work", "work"), TagUi("notes", "notes")),
            input = "",
            onInputChange = {},
            onCommitInput = {},
            onRemoveTag = {},
            onRemoveLastTag = {},
            caption = "Tags",
        )
        PasswordField(value = "hunter2", onValueChange = {}, caption = "Backup password", passwordVisible = false, onPasswordVisibleChange = {})
        CodeField(value = "7K2M9QXD4FTRHV3NP8WC6Y", onValueChange = {}, caption = "Recovery key", expectedLength = 27, onPasteClick = {})
        SwitchRow(title = "Enabled", checked = true, onCheckedChange = {}, supportingText = "Allow this keyword to expand on Mac.")
    }
}

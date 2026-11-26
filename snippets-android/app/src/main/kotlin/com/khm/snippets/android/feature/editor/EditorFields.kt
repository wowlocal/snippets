package com.khm.snippets.android.feature.editor

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import com.khm.snippets.android.R
import com.khm.snippets.android.data.ExistingKeywords
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.nav.LocalWindowLayout
import com.khm.snippets.android.nav.WidthClass
import com.khm.snippets.android.nav.WindowLayout
import com.khm.snippets.android.ui.components.KeywordField
import com.khm.snippets.android.ui.components.LabeledField
import com.khm.snippets.android.ui.components.SecureBodyPanel
import com.khm.snippets.android.ui.components.SwitchRow
import com.khm.snippets.android.ui.components.TagField
import com.khm.snippets.android.ui.components.rememberSnippetsHaptics
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/** Phone `Content` tab: Name, Snippet (or the secure panel), Preview Placeholders, footer. */
@Composable
internal fun EditorContentTab(
    state: EditorUiState,
    draft: EditorDraft,
    actions: EditorActions,
    focus: EditorFocus,
    bottomPadding: Dp,
) {
    FormColumn(isTwoPane = false, bottomPadding = bottomPadding) {
        NameField(state, draft, actions, focus)
        Spacer(Modifier.height(Dimens.fieldGap))
        BodyField(state, draft, actions, focus, minHeight = Dimens.bodyFieldMinHeight)
        if (state.preview != null) PreviewDisclosure(state.preview)
        Footer(state)
    }
}

/** Phone `Details` tab: Keyword, Tags, then the Enabled and Secure switches. */
@Composable
internal fun EditorDetailsTab(
    state: EditorUiState,
    draft: EditorDraft,
    actions: EditorActions,
    focus: EditorFocus,
    bottomPadding: Dp,
) {
    FormColumn(isTwoPane = false, bottomPadding = bottomPadding) {
        KeywordInput(state, draft, actions, focus)
        Spacer(Modifier.height(Dimens.fieldGap))
        TagsInput(state, draft, actions, focus)
        Switches(state, actions)
    }
}

/** The detail pane's single form (§6.9): every field in reading order, the preview always open. */
@Composable
internal fun EditorForm(
    state: EditorUiState,
    draft: EditorDraft,
    actions: EditorActions,
    focus: EditorFocus,
    bottomPadding: Dp,
) {
    FormColumn(isTwoPane = true, bottomPadding = bottomPadding) {
        NameField(state, draft, actions, focus)
        Spacer(Modifier.height(Dimens.fieldGap))
        BodyField(state, draft, actions, focus, minHeight = Dimens.bodyFieldMinHeightTwoPane)
        state.preview?.let { preview ->
            Spacer(Modifier.height(Dimens.fieldGap))
            FieldCaption(stringResource(R.string.editor_preview_caption))
            PreviewBlock(preview)
        }
        Spacer(Modifier.height(Dimens.fieldGap))
        KeywordInput(state, draft, actions, focus)
        Spacer(Modifier.height(Dimens.fieldGap))
        TagsInput(state, draft, actions, focus)
        Switches(state, actions)
        Footer(state)
    }
}


/**
 * One scrolling column of fields with the margins of the window: 16 dp on phones; centred at
 * 640 dp at medium widths; 720 dp in a detail pane, centred, or start-aligned with a 48 dp
 * margin from 1200 dp on (DESIGN.md §4).
 */
@Composable
private fun FormColumn(isTwoPane: Boolean, bottomPadding: Dp, content: @Composable ColumnScope.() -> Unit) {
    val layout = LocalWindowLayout.current
    val large = isTwoPane && layout.widthClass == WidthClass.Large
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
        contentAlignment = if (large) Alignment.TopStart else Alignment.TopCenter,
    ) {
        Column(
            modifier = Modifier
                .then(maxWidthOf(layout, isTwoPane))
                .fillMaxWidth()
                .padding(start = if (large) Spacing.xxxl else layout.formMargin(isTwoPane), end = layout.formMargin(isTwoPane))
                .padding(top = Spacing.l, bottom = bottomPadding),
            content = content,
        )
    }
}

private fun maxWidthOf(layout: WindowLayout, isTwoPane: Boolean): Modifier = when {
    isTwoPane -> Modifier.widthIn(max = Dimens.formMaxWidthExpanded)
    layout.widthClass == WidthClass.Medium -> Modifier.widthIn(max = Dimens.contentMaxWidthMedium)
    else -> Modifier
}

private fun WindowLayout.formMargin(isTwoPane: Boolean): Dp = if (isTwoPane) Dimens.marginMedium else horizontalMargin

@Composable
private fun NameField(state: EditorUiState, draft: EditorDraft, actions: EditorActions, focus: EditorFocus) {
    LabeledField(
        value = draft.name,
        onValueChange = actions::onNameChange,
        caption = stringResource(R.string.editor_name_caption),
        modifier = Modifier
            .focusRequester(focus.name)
            .onFocusChanged { actions.onFieldFocusChanged(EditorField.Name, it.hasFocus) },
        tag = EditorTags.NAME,
        placeholder = state.namePlaceholder.resolve(),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.Sentences,
            autoCorrectEnabled = true,
            keyboardType = KeyboardType.Text,
            imeAction = ImeAction.Next,
        ),
        keyboardActions = KeyboardActions(onNext = { if (!state.isSecure) focus.body.requestFocus() }),
    )
}

@Composable
private fun BodyField(state: EditorUiState, draft: EditorDraft, actions: EditorActions, focus: EditorFocus, minHeight: Dp) {
    if (state.isSecure) {
        FieldCaption(stringResource(R.string.editor_body_caption))
        SecureBodyPanel(
            state = draft.securePanel,
            onReveal = actions::onReveal,
            onLock = actions::onLock,
            onBodyChange = actions::onSecureBodyChange,
            onUnavailableAction = actions::onSecureUnavailableAction,
            bodyModifier = Modifier
                .focusRequester(focus.secureBody)
                .onFocusChanged { actions.onFieldFocusChanged(EditorField.SecureBody, it.isFocused) },
        )
        return
    }
    val tint = MaterialTheme.colorScheme.primary
    val transformation = remember(state.bodyPlaceholders, tint) { PlaceholderTint(state.bodyPlaceholders, tint) }
    LabeledField(
        value = draft.body,
        onValueChange = actions::onBodyChange,
        caption = stringResource(R.string.editor_body_caption),
        modifier = Modifier
            .focusRequester(focus.body)
            .onFocusChanged { actions.onFieldFocusChanged(EditorField.Body, it.hasFocus) },
        tag = EditorTags.BODY,
        placeholder = stringResource(R.string.editor_body_placeholder),
        singleLine = false,
        minHeight = minHeight,
        textStyle = SnippetsTheme.typography.monoBody,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Text,
            imeAction = ImeAction.Default,
        ),
        visualTransformation = transformation,
    )
}

/** `Preview Placeholders` (§6.4): collapsed by default; the state survives rotation. */
@Composable
private fun PreviewDisclosure(preview: String) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val reducedMotion = SnippetsTheme.reducedMotion
    val primary = MaterialTheme.colorScheme.primary
    Row(
        modifier = Modifier
            .padding(top = Spacing.s)
            .heightIn(min = Dimens.touchTarget)
            .clip(MaterialTheme.shapes.small)
            .clickable(role = Role.Button) { expanded = !expanded }
            .testTag(EditorTags.PREVIEW_TOGGLE)
            .padding(end = Spacing.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph(if (expanded) SnippetsIcon.ExpandLess else SnippetsIcon.ExpandMore, contentDescription = null, tint = primary)
        Text(stringResource(R.string.editor_preview_toggle), color = primary, style = MaterialTheme.typography.labelLarge)
    }
    AnimatedVisibility(
        visible = expanded,
        enter = if (reducedMotion) fadeIn(tween(Motion.REDUCED_FADE)) else expandVertically(tween(Motion.DISCLOSURE)) + fadeIn(tween(Motion.DISCLOSURE)),
        exit = if (reducedMotion) fadeOut(tween(Motion.REDUCED_FADE)) else shrinkVertically(tween(Motion.DISCLOSURE)) + fadeOut(tween(Motion.DISCLOSURE)),
    ) {
        PreviewBlock(preview)
    }
}

@Composable
private fun PreviewBlock(preview: String) {
    val colors = MaterialTheme.colorScheme
    val description = stringResource(R.string.editor_preview_description)
    Text(
        text = preview,
        modifier = Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .background(colors.surfaceContainerLow)
            .border(Dimens.borderThin, colors.outlineVariant, MaterialTheme.shapes.medium)
            .padding(Spacing.l)
            .semantics { contentDescription = description }
            .testTag(EditorTags.PREVIEW_TEXT),
        style = SnippetsTheme.typography.monoBody,
        color = colors.onSurfaceVariant,
    )
}

/** `Saved … at …`, or the save failure in `error`. Footer changes are not announced. */
@Composable
private fun Footer(state: EditorUiState) {
    val error = state.saveError
    val text = error?.resolve() ?: state.savedAt?.resolve() ?: return
    Text(
        text = text,
        modifier = Modifier
            .padding(top = Spacing.l)
            .testTag(EditorTags.FOOTER),
        style = MaterialTheme.typography.bodySmall,
        color = if (error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun KeywordInput(state: EditorUiState, draft: EditorDraft, actions: EditorActions, focus: EditorFocus) {
    val message = state.keywordMessage
    KeywordField(
        value = draft.keyword,
        onValueChange = actions::onKeywordChange,
        caption = stringResource(R.string.editor_keyword_caption),
        modifier = Modifier
            .focusRequester(focus.keyword)
            .onFocusChanged { actions.onFieldFocusChanged(EditorField.Keyword, it.hasFocus) }
            .onPreviewKeyEvent { event ->
                // Tab completes when it can; otherwise it moves focus as usual.
                event.key == Key.Tab && !event.isShiftPressed && event.type == KeyEventType.KeyDown && actions.onKeywordTab()
            },
        tag = EditorTags.KEYWORD,
        message = message?.text?.resolve(),
        messageIsWarning = message?.isWarning == true,
        keyboardActions = KeyboardActions(onNext = { focus.tags.requestFocus() }),
        helpWhileFocused = {
            KeywordHelp(
                keyword = draft.keyword.text,
                suggestions = state.keywordSuggestions,
                existing = state.existingKeywords,
                onSuggestion = actions::onKeywordSuggestion,
            )
        },
    )
}

/** The strip under the focused keyword field: suggestions while empty, else existing keywords. */
@Composable
private fun KeywordHelp(
    keyword: String,
    suggestions: List<String>,
    existing: ExistingKeywords,
    onSuggestion: (String) -> Unit,
) {
    val token = SnippetsTheme.typography.monoToken
    if (keyword.isEmpty()) {
        if (suggestions.isEmpty()) return
        Row(horizontalArrangement = Arrangement.spacedBy(Dimens.chipGap)) {
            suggestions.forEach { suggestion ->
                val description = stringResource(R.string.editor_keyword_suggestion_description, suggestion)
                SuggestionChip(
                    onClick = { onSuggestion(suggestion) },
                    label = { Text(stringResource(R.string.keyword_token, suggestion), style = token) },
                    modifier = Modifier
                        .testTag(EditorTags.keywordSuggestion(suggestion))
                        .semantics { contentDescription = description },
                )
            }
        }
        return
    }
    if (existing.shown.isEmpty()) return
    val separator = stringResource(R.string.editor_keyword_existing_separator)
    val tokens = existing.shown.map { stringResource(R.string.keyword_token, it) }
    val more = if (existing.moreCount > 0) pluralStringResource(R.plurals.editor_keyword_existing_more, existing.moreCount, existing.moreCount) else null
    val line = stringResource(R.string.editor_keyword_existing, (tokens + listOfNotNull(more)).joinToString(separator))
    val description = stringResource(R.string.editor_keyword_existing_description, tokens.joinToString(", ")) + " " +
        stringResource(R.string.editor_keyword_existing_hint)
    Text(
        text = line,
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = Dimens.fieldSupportingInset)
            .semantics { contentDescription = description }
            .testTag(EditorTags.KEYWORD_EXISTING),
        style = token,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        softWrap = false,
    )
}

@Composable
private fun TagsInput(state: EditorUiState, draft: EditorDraft, actions: EditorActions, focus: EditorFocus) {
    TagField(
        tags = state.tags,
        input = draft.tagInput,
        onInputChange = actions::onTagInputChange,
        onCommitInput = actions::onTagCommit,
        onRemoveTag = actions::onRemoveTag,
        onRemoveLastTag = actions::onRemoveLastTag,
        caption = stringResource(R.string.editor_tags_caption),
        modifier = Modifier.onFocusChanged { actions.onFieldFocusChanged(EditorField.Tags, it.hasFocus) },
        tag = EditorTags.TAGS,
        inputModifier = Modifier.focusRequester(focus.tags),
        onEnterKey = actions::onTagEnter,
    )
    if (state.tagCompletions.isNotEmpty()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(top = Spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(Dimens.chipGap),
        ) {
            state.tagCompletions.forEach { tag ->
                val description = stringResource(R.string.editor_tags_completion_description, tag.name)
                SuggestionChip(
                    onClick = { actions.onTagCompletion(tag) },
                    label = { Text(tag.name, modifier = Modifier.clearAndSetSemantics { }) },
                    modifier = Modifier
                        .testTag(EditorTags.tagCompletion(tag.folded))
                        .semantics { contentDescription = description },
                )
            }
        }
    }
}

@Composable
private fun Switches(state: EditorUiState, actions: EditorActions) {
    val haptics = rememberSnippetsHaptics()
    HorizontalDivider(
        modifier = Modifier.padding(top = Dimens.formSectionGap, bottom = Spacing.s),
        thickness = Dimens.borderThin,
        color = MaterialTheme.colorScheme.outlineVariant,
    )
    SwitchRow(
        modifier = Modifier.bleed(Dimens.marginCompact),
        title = stringResource(R.string.editor_enabled_title),
        checked = state.isEnabled,
        onCheckedChange = actions::onEnabledChange,
        tag = EditorTags.ENABLED,
        supportingText = stringResource(R.string.editor_enabled_supporting),
        clickLabel = stringResource(R.string.editor_enabled_click_label),
    )
    SwitchRow(
        modifier = Modifier.bleed(Dimens.marginCompact),
        title = stringResource(R.string.editor_secure_title),
        checked = state.isSecure,
        onCheckedChange = { secure ->
            haptics.toggle(secure)
            actions.onSecureChange(secure)
        },
        tag = EditorTags.SECURE,
        supportingText = stringResource(R.string.editor_secure_supporting),
        enabled = !state.isConverting,
        clickLabel = stringResource(R.string.editor_secure_click_label),
    )
}

/**
 * Widens a full-width list item by [amount] on both sides, so its own 16 dp inset lines its text
 * up with the fields of the form instead of adding to the form's margin.
 */
private fun Modifier.bleed(amount: Dp): Modifier = layout { measurable, constraints ->
    val extra = amount.roundToPx() * 2
    val wide = if (constraints.hasBoundedWidth) constraints.copy(minWidth = constraints.maxWidth + extra, maxWidth = constraints.maxWidth + extra) else constraints
    val placeable = measurable.measure(wide)
    val width = if (constraints.hasBoundedWidth) constraints.maxWidth else placeable.width
    layout(width, placeable.height) { placeable.placeRelative(-extra / 2, 0) }
}

@Composable
private fun FieldCaption(caption: String) {
    Text(
        text = caption,
        modifier = Modifier.padding(bottom = Dimens.fieldCaptionGap),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.labelLarge,
    )
}

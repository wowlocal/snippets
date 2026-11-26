package com.khm.snippets.android.ui.components

import android.view.inputmethod.EditorInfo
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuKeys
import androidx.compose.foundation.text.contextmenu.modifier.filterTextContextMenuComponents
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.sensitiveContent
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.LockReason
import com.khm.snippets.android.ui.model.ProtectedCause
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.UnavailableCause
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/**
 * The secure body panel (components.md §8). It takes the body field's place in the editor.
 *
 * The plaintext is composed only in [SecurePanelState.Revealed], and even then it is never in
 * the semantics tree: a stand-in node (`Protected secure snippet body`) describes the state.
 * The revealed field offers Paste and Select all only; Copy, Cut, Share and text actions are
 * removed. The caller sets `FLAG_SECURE` on the window while the state is revealed or unlocking.
 *
 * @param onReveal `Reveal Secure Content`.
 * @param onLock `Lock` in the revealed header.
 * @param onBodyChange Edits of the revealed body.
 * @param onUnavailableAction The button of the unavailable state (`Open Settings`, …).
 * @param bodyModifier Added to the revealed body field: a focus requester, focus observation.
 */
@Composable
fun SecureBodyPanel(
    state: SecurePanelState,
    onReveal: () -> Unit,
    onLock: () -> Unit,
    onBodyChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    onUnavailableAction: () -> Unit = {},
    bodyModifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val protectedMessage = (state as? SecurePanelState.Protected)?.let {
        stringResource(
            when (it.cause) {
                ProtectedCause.ScreenRecording -> R.string.secure_panel_recording
                ProtectedCause.UnprotectedDisplay -> R.string.secure_panel_display
            },
        )
    }
    val standInState: String? = when (state) {
        is SecurePanelState.Locked -> stringResource(R.string.secure_panel_standin_locked)
        SecurePanelState.Unlocking -> stringResource(R.string.secure_panel_standin_unlocking)
        is SecurePanelState.Revealed -> stringResource(R.string.secure_panel_standin_revealed)
        is SecurePanelState.Protected -> protectedMessage
        is SecurePanelState.Unavailable -> null
    }
    val footer: String? = when (state) {
        is SecurePanelState.Locked, SecurePanelState.Unlocking -> stringResource(R.string.secure_panel_footer_locked)
        is SecurePanelState.Revealed -> stringResource(R.string.secure_panel_footer_revealed)
        is SecurePanelState.Protected -> stringResource(
            when (state.cause) {
                ProtectedCause.ScreenRecording -> R.string.secure_panel_recording
                ProtectedCause.UnprotectedDisplay -> R.string.secure_panel_footer_display
            },
        )
        is SecurePanelState.Unavailable -> null
    }
    Column(modifier = modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = Dimens.securePanelMinHeight)
                .clip(MaterialTheme.shapes.medium)
                .background(colors.surfaceContainerHigh)
                .semantics { stateDescription = state.stateName }
                .testTag(TestTags.SECURE_PANEL),
        ) {
            if (standInState != null) {
                val description = stringResource(R.string.secure_panel_standin_description)
                // The describing sibling: what accessibility services get instead of the body.
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .semantics {
                            contentDescription = description
                            stateDescription = standInState
                        }
                        .testTag(TestTags.SECURE_STANDIN),
                )
            }
            when (state) {
                is SecurePanelState.Locked -> LockedContent(reason = state.reason, unlocking = false, onReveal = onReveal)
                SecurePanelState.Unlocking -> LockedContent(reason = null, unlocking = true, onReveal = onReveal)
                is SecurePanelState.Revealed -> RevealedContent(body = state.body, onLock = onLock, onBodyChange = onBodyChange, fieldModifier = bodyModifier)
                is SecurePanelState.Protected -> CenteredPanelContent {
                    Glyph(SnippetsIcon.VisibilityOff, contentDescription = null, tint = colors.onSurfaceVariant, size = Dimens.iconPanel)
                    PanelMessage(text = protectedMessage.orEmpty())
                }
                is SecurePanelState.Unavailable -> UnavailableContent(cause = state.cause, onAction = onUnavailableAction)
            }
        }
        if (footer != null) {
            Text(
                text = footer,
                modifier = Modifier
                    .padding(start = Dimens.fieldSupportingInset, end = Dimens.fieldSupportingInset, top = Dimens.fieldCaptionGap)
                    .testTag(TestTags.SECURE_FOOTER),
                color = colors.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun CenteredPanelContent(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = Dimens.securePanelMinHeight)
            .padding(Spacing.l),
        verticalArrangement = Arrangement.spacedBy(Spacing.m, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        content()
    }
}

@Composable
private fun PanelMessage(
    text: String,
    modifier: Modifier = Modifier,
    tag: String = TestTags.SECURE_MESSAGE,
) {
    Text(
        text = text,
        modifier = modifier.testTag(tag),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.bodyMedium,
        textAlign = TextAlign.Center,
    )
}

@Composable
private fun LockedContent(
    reason: LockReason?,
    unlocking: Boolean,
    onReveal: () -> Unit,
) {
    CenteredPanelContent {
        Glyph(SnippetsIcon.Lock, contentDescription = null, tint = SnippetsTheme.colors.secure, size = Dimens.iconPanel)
        if (reason != null) {
            PanelMessage(
                text = stringResource(
                    when (reason) {
                        LockReason.IdleTimeout -> R.string.secure_panel_reason_idle
                        LockReason.SessionExpired -> R.string.secure_panel_reason_expired
                        LockReason.LeftApp -> R.string.secure_panel_reason_left_app
                    },
                ),
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                tag = TestTags.SECURE_REASON,
            )
        }
        SnippetsButton(
            label = stringResource(if (unlocking) R.string.secure_panel_authenticating else R.string.secure_panel_reveal),
            onClick = onReveal,
            modifier = Modifier.testTag(TestTags.SECURE_REVEAL),
            level = ButtonLevel.Secondary,
            working = unlocking,
        )
    }
}

@Composable
private fun UnavailableContent(
    cause: UnavailableCause,
    onAction: () -> Unit,
) {
    CenteredPanelContent {
        Glyph(SnippetsIcon.Lock, contentDescription = null, tint = SnippetsTheme.colors.secure, size = Dimens.iconPanel)
        PanelMessage(
            text = stringResource(
                when (cause) {
                    UnavailableCause.NoScreenLock -> R.string.secure_panel_no_screen_lock
                    UnavailableCause.GitVaultNotSetUp -> R.string.secure_panel_git_vault_missing
                    UnavailableCause.VaultKeyMissing -> R.string.secure_panel_vault_key_missing
                },
            ),
        )
        SnippetsButton(
            label = stringResource(
                when (cause) {
                    UnavailableCause.NoScreenLock -> R.string.secure_panel_open_settings
                    UnavailableCause.GitVaultNotSetUp -> R.string.secure_panel_open_git
                    UnavailableCause.VaultKeyMissing -> R.string.secure_panel_open_secure
                },
            ),
            onClick = onAction,
            modifier = Modifier.testTag(TestTags.SECURE_UNAVAILABLE_ACTION),
            level = ButtonLevel.Secondary,
        )
    }
}

@Composable
private fun RevealedContent(
    body: String,
    onLock: () -> Unit,
    onBodyChange: (String) -> Unit,
    fieldModifier: Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val secure = SnippetsTheme.colors.secure
    val textStyle = SnippetsTheme.typography.monoBody.copy(color = colors.onSurface)
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = Dimens.securePanelHeaderMinHeight)
                .padding(start = Spacing.l, end = Spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Glyph(SnippetsIcon.LockOpen, contentDescription = null, tint = secure, size = Dimens.iconSmall)
            Spacer(Modifier.width(Spacing.s))
            Text(
                text = stringResource(R.string.secure_panel_revealed),
                modifier = Modifier.weight(1f),
                color = secure,
                style = MaterialTheme.typography.labelLarge,
            )
            SnippetsButton(
                label = stringResource(R.string.secure_panel_lock),
                onClick = onLock,
                modifier = Modifier.testTag(TestTags.SECURE_LOCK),
                level = ButtonLevel.Tertiary,
            )
        }
        HorizontalDivider(thickness = Dimens.borderThin, color = colors.outlineVariant)
        SecretTextInput {
            BasicTextField(
                value = body,
                onValueChange = onBodyChange,
                modifier = fieldModifier
                    .fillMaxWidth()
                    .padding(Spacing.l)
                    .sensitiveContent()
                    .blockCopyShortcuts()
                    .filterTextContextMenuComponents { component ->
                        component.key == TextContextMenuKeys.PasteKey || component.key == TextContextMenuKeys.SelectAllKey
                    }
                    // Never in the semantics tree; the stand-in node describes the state.
                    .clearAndSetSemantics { testTag = TestTags.SECURE_BODY },
                textStyle = textStyle,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Default,
                ),
                minLines = Dimens.securePanelBodyMinLines,
                cursorBrush = SolidColor(colors.primary),
                decorationBox = { innerTextField ->
                    Box {
                        if (body.isEmpty()) {
                            Text(
                                text = stringResource(R.string.secure_panel_placeholder),
                                style = textStyle,
                                color = colors.onSurfaceVariant,
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
 * Wraps fields that hold secret text: the keyboard is asked not to learn from the input
 * (`IME_FLAG_NO_PERSONALIZED_LEARNING`), and the selection toolbar offers Paste and Select all
 * only.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SecretTextInput(content: @Composable () -> Unit) {
    val platformToolbar = LocalTextToolbar.current
    val restrictedToolbar = remember(platformToolbar) { PasteOnlyTextToolbar(platformToolbar) }
    InterceptPlatformTextInput(
        interceptor = { request, nextHandler ->
            val incognito = PlatformTextInputMethodRequest { outAttributes ->
                request.createInputConnection(outAttributes).also {
                    outAttributes.imeOptions = outAttributes.imeOptions or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
                }
            }
            nextHandler.startInputMethod(incognito)
        },
    ) {
        CompositionLocalProvider(LocalTextToolbar provides restrictedToolbar, content = content)
    }
}

/** Swallows the hardware shortcuts that would copy or cut the selection. */
private fun Modifier.blockCopyShortcuts(): Modifier = onPreviewKeyEvent { event ->
    val copyOrCut = event.isCtrlPressed && (event.key == Key.C || event.key == Key.X || event.key == Key.Insert)
    val shiftDelete = event.isShiftPressed && event.key == Key.Delete
    copyOrCut || shiftDelete || event.key == Key.Copy || event.key == Key.Cut
}

private class PasteOnlyTextToolbar(private val delegate: TextToolbar) : TextToolbar {
    override val status: TextToolbarStatus get() = delegate.status

    override fun hide() = delegate.hide()

    override fun showMenu(
        rect: Rect,
        onCopyRequested: (() -> Unit)?,
        onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?,
        onSelectAllRequested: (() -> Unit)?,
    ) {
        delegate.showMenu(
            rect = rect,
            onCopyRequested = null,
            onPasteRequested = onPasteRequested,
            onCutRequested = null,
            onSelectAllRequested = onSelectAllRequested,
        )
    }

    override fun showMenu(
        rect: Rect,
        onCopyRequested: (() -> Unit)?,
        onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?,
        onSelectAllRequested: (() -> Unit)?,
        onAutofillRequested: (() -> Unit)?,
    ) {
        showMenu(rect, onCopyRequested, onPasteRequested, onCutRequested, onSelectAllRequested)
    }
}

@Preview(name = "Secure panel, light", widthDp = 375)
@Composable
private fun SecureBodyPanelPreviewLight() = PreviewSurface(darkTheme = false) { SecureBodyPanelPreviewContent() }

@Preview(name = "Secure panel, dark", widthDp = 375)
@Composable
private fun SecureBodyPanelPreviewDark() = PreviewSurface(darkTheme = true) { SecureBodyPanelPreviewContent() }

@Composable
private fun SecureBodyPanelPreviewContent() {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        SecureBodyPanel(SecurePanelState.Locked(LockReason.IdleTimeout), onReveal = {}, onLock = {}, onBodyChange = {})
        SecureBodyPanel(SecurePanelState.Revealed("sk-live-9f3"), onReveal = {}, onLock = {}, onBodyChange = {})
    }
}

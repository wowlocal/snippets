package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.SecretScreenUi
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/**
 * The secret screen template (components.md §14), shared by the vault recovery key, the Git
 * recovery code, the Cloud account key and the Cloud recovery kit.
 *
 * The value is shown once. `Copy` never advances the flow; the one acknowledgement is the
 * primary button. While [SecretScreenUi.isHidden] is true (the app is not resumed) everything
 * below the top bar is replaced by `Hidden while Snippets is in the background.`
 *
 * The caller owns the rest of the contract: `FLAG_SECURE` on the window, the route-scoped holder
 * of the value, the sensitive clip and its clearing, and back (cancel where the screen allows
 * it, otherwise [SecretLeaveDialog]).
 *
 * @param onCopy Copies the value as a sensitive clip; perform [SnippetsHaptic.SecretCopied].
 * @param onDone The primary button.
 * @param onClose The close button, shown only when [SecretScreenUi.canClose].
 */
@Composable
fun SecretScreen(
    ui: SecretScreenUi,
    onCopy: () -> Unit,
    onDone: () -> Unit,
    onClose: () -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    // Two tags on the root: the route's own, and inside it the template's.
    Box(modifier = modifier.testTag(ui.routeTag), propagateMinConstraints = true) {
        SecretScreenContent(ui = ui, onCopy = onCopy, onDone = onDone, onClose = onClose, compact = compact)
    }
}

@Composable
private fun SecretScreenContent(
    ui: SecretScreenUi,
    onCopy: () -> Unit,
    onDone: () -> Unit,
    onClose: () -> Unit,
    compact: Boolean,
) {
    val colors = MaterialTheme.colorScheme
    FullScreenDialogScaffold(
        title = ui.title,
        onClose = onClose,
        compact = compact,
        modifier = Modifier.testTag(TestTags.SECRET_SCREEN),
        showClose = ui.canClose,
        closeDescription = ui.closeDescription ?: stringResource(R.string.action_cancel),
        closeTag = TestTags.SECRET_CLOSE,
        bottomBar = if (ui.isHidden) {
            null
        } else {
            {
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                    SnippetsButton(
                        label = ui.doneTitle,
                        onClick = onDone,
                        modifier = Modifier
                            .then(if (compact) Modifier.fillMaxWidth() else Modifier)
                            .testTag(TestTags.SECRET_DONE),
                    )
                }
            }
        },
    ) {
        if (ui.isHidden) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = Spacing.xxxl)
                    .testTag(TestTags.SECRET_HIDDEN),
                verticalArrangement = Arrangement.spacedBy(Spacing.m),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Glyph(SnippetsIcon.Lock, contentDescription = null, tint = SnippetsTheme.colors.secure, size = Dimens.iconPanel)
                Text(
                    text = stringResource(R.string.secret_hidden),
                    color = colors.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                )
            }
            return@FullScreenDialogScaffold
        }
        Spacer(Modifier.height(Spacing.s))
        Text(
            text = ui.heading,
            modifier = Modifier
                .testTag(TestTags.SECRET_HEADING)
                .semantics { heading() },
            style = MaterialTheme.typography.headlineSmall,
        )
        Spacer(Modifier.height(Spacing.s))
        Text(
            text = ui.body,
            modifier = Modifier.testTag(TestTags.SECRET_BODY),
            color = colors.onSurfaceVariant,
            style = MaterialTheme.typography.bodyLarge,
        )
        Spacer(Modifier.height(Spacing.l))
        SecretBlock(value = ui.code, groupSize = ui.groupSize)
        Spacer(Modifier.height(Spacing.m))
        SecretCopyAction(
            label = ui.copyTitle ?: stringResource(R.string.action_copy),
            onCopy = onCopy,
            copiedMessage = ui.copiedMessage,
        )
        if (ui.note != null) {
            Spacer(Modifier.height(Spacing.l))
            Text(
                text = ui.note,
                modifier = Modifier.testTag(TestTags.SECRET_NOTE),
                color = colors.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

private fun previewSecret(copied: Boolean, hidden: Boolean = false) = SecretScreenUi(
    routeTag = "secure.recovery-key",
    title = "Recovery Key",
    heading = "Save Your Recovery Key",
    body = "Store this somewhere safe. It is the only way to recover secure snippets if the vault key on this device is lost. Snippets can’t show it again.",
    code = "7K2M9QXD4FTRHV3NP8WC6YJAB5G",
    doneTitle = "I’ve Saved It",
    copiedMessage = if (copied) "Copied. It clears from the clipboard in 5 minutes." else null,
    canClose = true,
    isHidden = hidden,
)

@Preview(name = "Secret screen, light", widthDp = 375, heightDp = 640)
@Composable
private fun SecretScreenPreviewLight() = PreviewSurface(darkTheme = false, padded = false) {
    SecretScreen(previewSecret(copied = true), onCopy = {}, onDone = {}, onClose = {}, compact = true)
}

@Preview(name = "Secret screen, dark", widthDp = 375, heightDp = 640)
@Composable
private fun SecretScreenPreviewDark() = PreviewSurface(darkTheme = true, padded = false) {
    SecretScreen(previewSecret(copied = false, hidden = true), onCopy = {}, onDone = {}, onClose = {}, compact = true)
}

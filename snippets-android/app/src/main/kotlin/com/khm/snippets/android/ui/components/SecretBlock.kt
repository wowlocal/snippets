package com.khm.snippets.android.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.text
import androidx.compose.ui.sensitiveContent
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CodeFormat
import com.khm.snippets.android.ui.model.SecretVariant
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing
import com.khm.snippets.android.ui.theme.cappedAtFontScale

/** The prefix of an SSH fingerprint; it gets its own line. */
private const val FINGERPRINT_PREFIX = "SHA256:"

/**
 * A bordered block for a value the user must copy or compare exactly (components.md §9).
 *
 * - [SecretVariant.Code]: [value] is the raw symbols; they are drawn in groups that never break,
 *   with the hyphen at the end of its group. Not selectable; spelled out for screen readers.
 * - [SecretVariant.Comparison]: one centred line.
 * - [SecretVariant.Fingerprint]: `SHA256:` on the first line, then groups of 8; selectable.
 * - [SecretVariant.PublicKey]: the whole key, soft-wrapped anywhere; selectable.
 *
 * The node tagged `secret.code` carries the displayed value as its text.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SecretBlock(
    value: String,
    modifier: Modifier = Modifier,
    variant: SecretVariant = SecretVariant.Code,
    groupSize: Int = CodeFormat.DEFAULT_GROUP_SIZE,
) {
    val colors = MaterialTheme.colorScheme
    val typography = SnippetsTheme.typography
    OutlinedCard(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.outlinedCardColors(
            containerColor = colors.surfaceContainerLow,
            contentColor = colors.onSurface,
        ),
        border = BorderStroke(Dimens.borderThin, colors.outlineVariant),
    ) {
        when (variant) {
            SecretVariant.Code -> {
                val groups = CodeFormat.groups(value, groupSize)
                val spelled = CodeFormat.spelled(value, groupSize)
                val displayed = CodeFormat.grouped(value, groupSize)
                val style = typography.monoCode.cappedAtFontScale()
                FlowRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(Dimens.secretBlockPadding)
                        .sensitiveContent()
                        .clearAndSetSemantics {
                            testTag = TestTags.SECRET_CODE
                            contentDescription = spelled
                            text = AnnotatedString(displayed)
                        },
                    horizontalArrangement = Arrangement.Center,
                ) {
                    groups.forEachIndexed { index, group ->
                        Text(
                            text = if (index < groups.lastIndex) group + CodeFormat.SEPARATOR else group,
                            style = style,
                            maxLines = 1,
                            softWrap = false,
                        )
                    }
                }
            }
            SecretVariant.Comparison -> {
                val spelled = value.trim().split(Regex("\\s+")).joinToString(", ") { it.toList().joinToString(" ") }
                Text(
                    text = value,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(Dimens.secretBlockPadding)
                        .sensitiveContent()
                        .clearAndSetSemantics {
                            testTag = TestTags.SECRET_CODE
                            contentDescription = spelled
                            text = AnnotatedString(value)
                        },
                    style = typography.monoCodeLarge.cappedAtFontScale(),
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    softWrap = false,
                )
            }
            SecretVariant.Fingerprint -> {
                val digest = value.removePrefix(FINGERPRINT_PREFIX)
                val hasPrefix = digest.length != value.length
                val grouped = CodeFormat.groups(digest, Dimens.fingerprintGroupSize).joinToString(" ")
                val displayed = if (hasPrefix) "$FINGERPRINT_PREFIX\n$grouped" else grouped
                val description = stringResource(
                    R.string.secret_fingerprint_description,
                    digest.toList().joinToString(" "),
                )
                SelectionContainer {
                    Text(
                        text = displayed,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(Dimens.secretBlockPadding)
                            .testTag(TestTags.SECRET_CODE)
                            .semantics { contentDescription = description },
                        style = typography.monoKey,
                    )
                }
            }
            SecretVariant.PublicKey -> {
                val description = stringResource(R.string.secret_public_key_description, CodeFormat.ending(value))
                SelectionContainer {
                    Text(
                        text = value,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(Dimens.secretBlockPadding)
                            .testTag(TestTags.SECRET_CODE)
                            .semantics { contentDescription = description },
                        style = typography.monoKey,
                    )
                }
            }
        }
    }
}

/**
 * The copy affordance that sits directly under a [SecretBlock]: a tonal button and, after a
 * sensitive copy, the screen's "copied" line, which stays while the screen is open.
 *
 * @param label `Copy`, `Copy Public Key`, …
 * @param copiedMessage For example `Copied. It clears from the clipboard in 2 minutes.`, or null
 *   before the first copy. Public values pass null and follow the ordinary copy rules.
 */
@Composable
fun SecretCopyAction(
    label: String,
    onCopy: () -> Unit,
    modifier: Modifier = Modifier,
    copiedMessage: String? = null,
) {
    Column(modifier = modifier, horizontalAlignment = Alignment.Start) {
        SnippetsButton(
            label = label,
            onClick = onCopy,
            modifier = Modifier.testTag(TestTags.SECRET_COPY),
            level = ButtonLevel.Secondary,
            icon = SnippetsIcon.ContentCopy,
        )
        if (copiedMessage != null) {
            Text(
                text = copiedMessage,
                modifier = Modifier
                    .padding(top = Spacing.xs)
                    .testTag(TestTags.SECRET_COPIED)
                    .semantics { liveRegion = LiveRegionMode.Polite },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Preview(name = "Secret block, light", widthDp = 375)
@Composable
private fun SecretBlockPreviewLight() = PreviewSurface(darkTheme = false) { SecretBlockPreviewContent() }

@Preview(name = "Secret block, dark", widthDp = 375)
@Composable
private fun SecretBlockPreviewDark() = PreviewSurface(darkTheme = true) { SecretBlockPreviewContent() }

@Composable
private fun SecretBlockPreviewContent() {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SecretBlock("7K2M9QXD4FTRHV3NP8WC6YJAB5G")
        SecretCopyAction("Copy", onCopy = {}, copiedMessage = "Copied. It clears from the clipboard in 5 minutes.")
        SecretBlock("482 913", variant = SecretVariant.Comparison)
        SecretBlock("SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8", variant = SecretVariant.Fingerprint)
        SecretBlock("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl snippets", variant = SecretVariant.PublicKey)
    }
}

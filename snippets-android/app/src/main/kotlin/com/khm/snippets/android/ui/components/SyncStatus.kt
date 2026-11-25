package com.khm.snippets.android.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLocale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.collapse
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.expand
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.ProblemSeverity
import com.khm.snippets.android.ui.model.ProblemUi
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind
import com.khm.snippets.android.ui.model.SyncReviewUi
import com.khm.snippets.android.ui.model.SyncStatusUi
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/**
 * The one mapping from a sync state to its glyph and tint (components.md §7.1), used by the
 * library row, the sync sheet, Settings rows and the Git and Cloud screens. Decorative: the text
 * next to it carries the meaning.
 *
 * @param tint Overrides the state's own tint, for example on a coloured card.
 */
@Composable
fun SyncStatusGlyph(
    glyph: SyncGlyph,
    modifier: Modifier = Modifier,
    size: Dp = Dimens.iconSyncRow,
    tint: Color = Color.Unspecified,
) {
    val colors = MaterialTheme.colorScheme
    val extended = SnippetsTheme.colors
    if (glyph == SyncGlyph.Syncing) {
        Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                modifier = Modifier.size(Dimens.spinnerSmall),
                color = if (tint != Color.Unspecified) tint else colors.primary,
                strokeWidth = Dimens.spinnerStroke,
            )
        }
        return
    }
    val icon = when (glyph) {
        SyncGlyph.Off -> SnippetsIcon.Sync
        SyncGlyph.Preparing -> SnippetsIcon.Cloud
        SyncGlyph.Syncing -> SnippetsIcon.Sync
        SyncGlyph.WaitingForFirstFetch -> SnippetsIcon.CloudDownload
        SyncGlyph.Synced -> SnippetsIcon.CloudDone
        SyncGlyph.Offline -> SnippetsIcon.CloudOff
        SyncGlyph.NeedsAuthentication -> SnippetsIcon.PersonAlert
        SyncGlyph.NeedsAttention -> SnippetsIcon.Warning
        SyncGlyph.WaitingForVault -> SnippetsIcon.LockClock
        SyncGlyph.UpdateRequired -> SnippetsIcon.SystemUpdate
        SyncGlyph.Halted, SyncGlyph.HaltedDataAtRisk -> SnippetsIcon.SyncProblem
    }
    val ownTint = when (glyph) {
        SyncGlyph.NeedsAuthentication, SyncGlyph.NeedsAttention, SyncGlyph.UpdateRequired, SyncGlyph.Halted -> extended.warning
        SyncGlyph.WaitingForVault -> extended.secure
        SyncGlyph.HaltedDataAtRisk -> colors.error
        else -> colors.onSurfaceVariant
    }
    Glyph(
        icon = icon,
        contentDescription = null,
        modifier = modifier,
        tint = if (tint != Color.Unspecified) tint else ownTint,
        size = size,
    )
}

/**
 * The quiet library sync row (components.md §7.2): first item of the list, opens the sync
 * status sheet. Changes are not announced.
 */
@Composable
fun SyncStatusRow(
    status: SyncStatusUi,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = stringResource(R.string.sync_row_label)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Dimens.syncRowMinHeight)
            .clickable(
                onClickLabel = stringResource(R.string.sync_row_click_label),
                role = Role.Button,
                onClick = onClick,
            )
            .semantics {
                contentDescription = label
                stateDescription = status.text
            }
            .testTag(TestTags.LIBRARY_SYNC_ROW)
            .padding(horizontal = Dimens.marginCompact, vertical = Spacing.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SyncStatusGlyph(status.glyph)
        Spacer(Modifier.width(Spacing.m))
        Text(
            text = status.text,
            modifier = Modifier.testTag(TestTags.LIBRARY_SYNC_ROW_TEXT),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The Review card (components.md §7.3) that replaces the quiet row while sync needs the user.
 * It cannot be dismissed.
 *
 * @param onClick Tap on the card body: the Review screen for halts, Sync settings otherwise.
 * @param onAction Tap on the button.
 */
@Composable
fun SyncReviewCard(
    review: SyncReviewUi,
    onClick: () -> Unit,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val extended = SnippetsTheme.colors
    val (container, content) = when (review.kind) {
        SyncReviewKind.HaltedDataAtRisk -> colors.errorContainer to colors.onErrorContainer
        SyncReviewKind.Halted, SyncReviewKind.NeedsAttention -> extended.warningContainer to extended.onWarningContainer
        SyncReviewKind.WaitingForVault -> extended.secureContainer to extended.onSecureContainer
    }
    val title = stringResource(
        when (review.kind) {
            SyncReviewKind.Halted, SyncReviewKind.HaltedDataAtRisk -> R.string.sync_card_title_stopped
            SyncReviewKind.NeedsAttention -> R.string.sync_card_title_attention
            SyncReviewKind.WaitingForVault -> R.string.sync_card_title_waiting
        },
    )
    val label = stringResource(R.string.sync_row_label)
    val locale = LocalLocale.current.platformLocale
    val actionTitle = review.actionTitle
    val value = if (actionTitle != null) {
        stringResource(R.string.sync_card_value_action, review.text, actionTitle)
    } else {
        review.text
    }
    Card(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Dimens.marginCompact, vertical = Dimens.cardMarginVertical)
            .testTag(TestTags.LIBRARY_SYNC_CARD),
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.cardColors(containerColor = container, contentColor = content),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(MaterialTheme.shapes.medium)
                .clickable(
                    // The click label is the button title in lower case.
                    onClickLabel = actionTitle?.lowercase(locale),
                    role = Role.Button,
                    onClick = onClick,
                )
                .semantics {
                    contentDescription = label
                    stateDescription = value
                }
                .padding(
                    start = Dimens.cardPadding,
                    end = Dimens.cardPadding,
                    top = Dimens.cardPadding,
                    bottom = if (actionTitle != null) 0.dp else Dimens.cardPadding,
                ),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SyncStatusGlyph(review.glyph, tint = content)
                Spacer(Modifier.width(Spacing.s))
                Text(
                    text = title,
                    modifier = Modifier.testTag(TestTags.LIBRARY_SYNC_CARD_TITLE),
                    style = MaterialTheme.typography.titleSmall,
                )
            }
            Text(
                text = review.text,
                modifier = Modifier
                    .padding(top = Spacing.xs)
                    .testTag(TestTags.LIBRARY_SYNC_CARD_TEXT),
                style = MaterialTheme.typography.bodyMedium,
                maxLines = Dimens.reviewCardMaxLines,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (actionTitle != null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = Dimens.cardPadding, end = Dimens.cardPadding, top = Spacing.s, bottom = Spacing.m),
                contentAlignment = Alignment.CenterEnd,
            ) {
                SnippetsButton(
                    label = actionTitle,
                    onClick = onAction,
                    modifier = Modifier.testTag(TestTags.LIBRARY_SYNC_CARD_ACTION),
                    level = ButtonLevel.Secondary,
                    working = review.isActionRunning,
                )
            }
        }
    }
}

/**
 * A `Details` disclosure, collapsed by default, that reveals a failure code with a copy button.
 * Used by problem cards and the Review screen.
 *
 * @param onCopyCode An ordinary (non-sensitive) copy of [code].
 */
@Composable
fun CodeDisclosure(
    code: String,
    onCopyCode: () -> Unit,
    modifier: Modifier = Modifier,
    detailsTag: String? = null,
    codeTag: String? = null,
    copyTag: String? = null,
    initiallyExpanded: Boolean = false,
) {
    var expanded by rememberSaveable { mutableStateOf(initiallyExpanded) }
    val reducedMotion = SnippetsTheme.reducedMotion
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .heightIn(min = Dimens.touchTarget)
                .clip(MaterialTheme.shapes.small)
                .clickable(role = Role.Button) { expanded = !expanded }
                .semantics {
                    if (expanded) {
                        collapse {
                            expanded = false
                            true
                        }
                    } else {
                        expand {
                            expanded = true
                            true
                        }
                    }
                }
                .then(if (detailsTag != null) Modifier.testTag(detailsTag) else Modifier)
                .padding(end = Spacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.action_details),
                color = MaterialTheme.colorScheme.primary,
                style = MaterialTheme.typography.labelLarge,
            )
            Glyph(
                icon = if (expanded) SnippetsIcon.ExpandLess else SnippetsIcon.ExpandMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
        }
        AnimatedVisibility(
            visible = expanded,
            enter = if (reducedMotion) {
                fadeIn(tween(Motion.REDUCED_FADE))
            } else {
                expandVertically(tween(Motion.DISCLOSURE)) + fadeIn(tween(Motion.DISCLOSURE))
            },
            exit = if (reducedMotion) {
                fadeOut(tween(Motion.REDUCED_FADE))
            } else {
                shrinkVertically(tween(Motion.DISCLOSURE)) + fadeOut(tween(Motion.DISCLOSURE))
            },
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.problem_code, code),
                    modifier = Modifier
                        .weight(1f)
                        .then(if (codeTag != null) Modifier.testTag(codeTag) else Modifier),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = SnippetsTheme.typography.monoKey,
                )
                SnippetsIconButton(
                    icon = SnippetsIcon.ContentCopy,
                    contentDescription = stringResource(R.string.action_copy),
                    onClick = onCopyCode,
                    tag = copyTag,
                )
            }
        }
    }
}

/**
 * A persistent, typed failure (components.md §7.4) for the Git and Cloud screens and forms.
 * Never a toast. It is an assertive live region when it first appears.
 *
 * Test tags are `<tagArea>.error.<code>` with `.title`, `.message`, `.action`, `.action-2`,
 * `.details`, `.code`, `.code-copy`.
 *
 * @param tagArea The screen's tag area, for example `git`.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ProblemCard(
    problem: ProblemUi,
    tagArea: String,
    onCopyCode: () -> Unit,
    modifier: Modifier = Modifier,
    onPrimaryAction: () -> Unit = {},
    onSecondaryAction: () -> Unit = {},
) {
    val accent = when (problem.severity) {
        ProblemSeverity.Error -> MaterialTheme.colorScheme.error
        ProblemSeverity.Warning -> SnippetsTheme.colors.warning
    }
    val tag = TestTags.problem(tagArea, problem.code)
    OutlinedCard(
        modifier = modifier
            .fillMaxWidth()
            .testTag(tag)
            .semantics { liveRegion = LiveRegionMode.Assertive },
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(Dimens.borderThin, accent),
    ) {
        Column(
            modifier = Modifier.padding(
                start = Dimens.cardPadding,
                end = Dimens.cardPadding,
                top = Dimens.cardPadding,
                bottom = Spacing.s,
            ),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Glyph(
                    icon = if (problem.severity == ProblemSeverity.Error) SnippetsIcon.Error else SnippetsIcon.Warning,
                    contentDescription = null,
                    tint = accent,
                )
                Spacer(Modifier.width(Spacing.s))
                Text(
                    text = problem.title,
                    modifier = Modifier
                        .testTag(tag + TestTags.Problem.TITLE)
                        .semantics { heading() },
                    color = accent,
                    style = MaterialTheme.typography.titleSmall,
                )
            }
            Text(
                text = problem.message,
                modifier = Modifier
                    .padding(top = Spacing.s)
                    .testTag(tag + TestTags.Problem.MESSAGE),
                color = MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.bodyMedium,
            )
            if (problem.primaryAction != null || problem.secondaryAction != null) {
                FlowRow(
                    // Pulled back by the text button's own padding so the label lines up with the text.
                    modifier = Modifier.padding(top = Spacing.xs).offset(x = -Spacing.m),
                    horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
                ) {
                    problem.primaryAction?.let { title ->
                        SnippetsButton(
                            label = title,
                            onClick = onPrimaryAction,
                            modifier = Modifier.testTag(tag + TestTags.Problem.ACTION),
                            level = ButtonLevel.Tertiary,
                        )
                    }
                    problem.secondaryAction?.let { title ->
                        SnippetsButton(
                            label = title,
                            onClick = onSecondaryAction,
                            modifier = Modifier.testTag(tag + TestTags.Problem.ACTION_2),
                            level = ButtonLevel.Tertiary,
                        )
                    }
                }
            }
            CodeDisclosure(
                code = problem.code,
                onCopyCode = onCopyCode,
                detailsTag = tag + TestTags.Problem.DETAILS,
                codeTag = tag + TestTags.Problem.CODE,
                copyTag = tag + TestTags.Problem.CODE_COPY,
            )
        }
    }
}

@Preview(name = "Sync status, light", widthDp = 375)
@Composable
private fun SyncStatusPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { SyncStatusPreviewContent() }

@Preview(name = "Sync status, dark", widthDp = 375)
@Composable
private fun SyncStatusPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { SyncStatusPreviewContent() }

@Composable
private fun SyncStatusPreviewContent() {
    Column {
        SyncStatusRow(SyncStatusUi(SyncGlyph.Synced, "Synced at 9:04 PM"), onClick = {})
        SyncReviewCard(
            review = SyncReviewUi(
                kind = SyncReviewKind.HaltedDataAtRisk,
                glyph = SyncGlyph.HaltedDataAtRisk,
                text = "Stopped because an unusually large deletion arrived.",
                actionTitle = "Confirm Deletions",
            ),
            onClick = {},
            onAction = {},
        )
        ProblemCard(
            problem = ProblemUi(
                code = "git_http_401",
                title = "Access Token Refused",
                message = "The Git host didn’t accept the access token.",
                primaryAction = "Enter a New Token",
            ),
            tagArea = "git",
            onCopyCode = {},
            modifier = Modifier.padding(Dimens.marginCompact),
        )
    }
}

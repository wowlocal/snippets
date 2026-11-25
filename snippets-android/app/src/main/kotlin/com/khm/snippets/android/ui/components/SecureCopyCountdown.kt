package com.khm.snippets.android.ui.components

import android.os.SystemClock
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CountdownFormat
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing
import com.khm.snippets.android.ui.theme.TABULAR_DIGITS_FEATURES
import kotlinx.coroutines.delay

/** How often the row reads the clock: the bar moves by less than a pixel in between. */
private const val COUNTDOWN_TICK_MILLIS = 50L

/** Stands in for the name while the sentence is split around it. */
internal const val NAME_ARGUMENT = "\u0000"

/**
 * The pinned row shown after every secure copy (components.md §10):
 * `Copied “name”. Clears in 0:42`, `Clear Now` and a bar that drains with the real deadline.
 *
 * The row draws what it is given: its owner (an application-scoped holder) clears the clipboard
 * at the deadline, switches to [CountdownUi.Cleared] for 3 s and then removes the row.
 *
 * @param nowMillis The clock the deadline is measured on.
 * @param announce Speaks the appearance and `Clipboard cleared.`; the ticking text is never a
 *   live region.
 */
@Composable
fun SecureCopyCountdown(
    state: CountdownUi,
    onClearNow: () -> Unit,
    modifier: Modifier = Modifier,
    nowMillis: () -> Long = SystemClock::elapsedRealtime,
    announce: Boolean = true,
) {
    val extended = SnippetsTheme.colors
    val announcer = rememberAnnouncer()
    val currentNow by rememberUpdatedState(nowMillis)

    var remainingMillis by remember { mutableLongStateOf(remainingOf(state, nowMillis())) }
    LaunchedEffect(state) {
        if (state is CountdownUi.Running) {
            while (true) {
                remainingMillis = remainingOf(state, currentNow())
                delay(COUNTDOWN_TICK_MILLIS)
            }
        } else {
            remainingMillis = 0
        }
    }

    val clearedText = stringResource(R.string.countdown_cleared)
    val appearAnnouncement = (state as? CountdownUi.Running)?.let {
        stringResource(R.string.countdown_announcement, it.name)
    }
    if (announce) {
        LaunchedEffect(appearAnnouncement, state is CountdownUi.Cleared) {
            when {
                state is CountdownUi.Cleared -> announcer.announce(clearedText)
                appearAnnouncement != null -> announcer.announce(appearAnnouncement)
            }
        }
    }

    val clearLabel = stringResource(R.string.countdown_clear)
    val currentOnClearNow by rememberUpdatedState(onClearNow)
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag(TestTags.COUNTDOWN_ROW)
            .semantics {
                if (state is CountdownUi.Running) {
                    customActions = listOf(
                        CustomAccessibilityAction(clearLabel) {
                            currentOnClearNow()
                            true
                        },
                    )
                }
            },
        color = extended.secureContainer,
        contentColor = extended.onSecureContainer,
    ) {
        Column {
            val textStyle = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = TABULAR_DIGITS_FEATURES)
            // At large font scales one line cannot hold the sentence and the button: the time
            // left moves to a second line and the button under the text.
            val stacked = LocalDensity.current.fontScale >= Dimens.largeFontScale
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = Dimens.countdownMinHeight - Dimens.countdownBarHeight)
                    .padding(start = Dimens.marginCompact, end = if (stacked) Dimens.marginCompact else Spacing.xs)
                    .padding(vertical = if (stacked) Spacing.s else 0.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Glyph(SnippetsIcon.Timer, contentDescription = null, size = Dimens.iconSyncRow)
                Spacer(Modifier.width(Spacing.m))
                when (state) {
                    is CountdownUi.Running -> {
                        val time = CountdownFormat.remaining(remainingMillis)
                        val parts = countdownSentence(stringResource(R.string.countdown_text, NAME_ARGUMENT, time), state.name)
                        val textModifier = Modifier
                            .weight(1f)
                            .clearAndSetSemantics {
                                testTag = TestTags.COUNTDOWN_TEXT
                                text = AnnotatedString(parts.sentence)
                            }
                        // Only the name is ever cut; what follows it always shows in full.
                        if (stacked) {
                            Column(modifier = textModifier) {
                                Row {
                                    Text(
                                        text = parts.head,
                                        modifier = Modifier.weight(1f, fill = false),
                                        style = textStyle,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Text(text = parts.closing, style = textStyle, maxLines = 1, softWrap = false)
                                }
                                Text(text = parts.rest, style = textStyle)
                            }
                        } else {
                            Row(modifier = textModifier) {
                                Text(
                                    text = parts.head,
                                    modifier = Modifier.weight(1f, fill = false),
                                    style = textStyle,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(text = parts.tail, style = textStyle, maxLines = 1, softWrap = false)
                            }
                            ClearNowButton(label = clearLabel, onClick = onClearNow)
                        }
                    }
                    CountdownUi.Cleared -> Text(
                        text = clearedText,
                        modifier = Modifier
                            .weight(1f)
                            .testTag(TestTags.COUNTDOWN_TEXT),
                        style = textStyle,
                        maxLines = if (stacked) Int.MAX_VALUE else 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (stacked && state is CountdownUi.Running) {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(end = Spacing.xs),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    ClearNowButton(label = clearLabel, onClick = onClearNow)
                }
            }
            if (state is CountdownUi.Running) {
                LinearProgressIndicator(
                    progress = { CountdownFormat.fraction(remainingMillis, state.totalMillis) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Dimens.countdownBarHeight)
                        .testTag(TestTags.COUNTDOWN_PROGRESS),
                    color = extended.secure,
                    trackColor = Color.Transparent,
                    strokeCap = StrokeCap.Butt,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
            } else {
                Spacer(Modifier.height(Dimens.countdownBarHeight))
            }
        }
    }
}

@Composable
private fun ClearNowButton(label: String, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.testTag(TestTags.COUNTDOWN_CLEAR),
        colors = ButtonDefaults.textButtonColors(contentColor = SnippetsTheme.colors.onSecureContainer),
    ) {
        Text(label)
    }
}

/**
 * The countdown sentence cut into the parts the row draws.
 *
 * @param head Everything up to and including the name: the only part that may be cut.
 * @param tail Everything after the name.
 * @param closing The punctuation that closes the name (the start of [tail] up to its first space).
 * @param rest [tail] without [closing]: `Clears in 0:42`.
 */
internal data class CountdownSentence(val head: String, val tail: String, val closing: String, val rest: String) {
    val sentence: String get() = head + tail
}

/** Splits [template], which holds [NAME_ARGUMENT] where the name goes, around [name]. */
internal fun countdownSentence(template: String, name: String): CountdownSentence {
    val head = template.substringBefore(NAME_ARGUMENT) + name
    val tail = template.substringAfter(NAME_ARGUMENT, missingDelimiterValue = "")
    val closing = tail.substringBefore(' ')
    val rest = tail.substringAfter(' ', missingDelimiterValue = "")
    return CountdownSentence(head = head, tail = tail, closing = closing, rest = rest)
}

private fun remainingOf(state: CountdownUi, now: Long): Long = when (state) {
    is CountdownUi.Running -> (state.deadlineMillis - now).coerceAtLeast(0)
    CountdownUi.Cleared -> 0
}

@Preview(name = "Countdown, light", widthDp = 375)
@Composable
private fun SecureCopyCountdownPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { CountdownPreviewContent() }

@Preview(name = "Countdown, dark", widthDp = 375)
@Composable
private fun SecureCopyCountdownPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { CountdownPreviewContent() }

@Composable
private fun CountdownPreviewContent() {
    Column {
        SecureCopyCountdown(
            state = CountdownUi.Running(name = "Atlas API token", deadlineMillis = 42_000),
            onClearNow = {},
            nowMillis = { 0 },
            announce = false,
        )
        SecureCopyCountdown(state = CountdownUi.Cleared, onClearNow = {}, announce = false)
    }
}

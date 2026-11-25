package com.khm.snippets.android.ui.components

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.StepState
import com.khm.snippets.android.ui.model.StepUi
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme

/**
 * The steps of a running operation (components.md §13). Only real steps, in the order the
 * operation runs them. The running step is a polite live region, so each transition announces
 * the new label. A failed step is followed by a problem card under the list.
 *
 * Test tags are `progress.step.<n>` (1-based); the state is the `stateDescription`.
 */
@Composable
fun ProgressSteps(
    steps: List<StepUi>,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        steps.forEachIndexed { index, step ->
            ProgressStepRow(step = step, number = index + 1)
        }
    }
}

@Composable
private fun ProgressStepRow(step: StepUi, number: Int) {
    val colors = MaterialTheme.colorScheme
    val state = stringResource(
        when (step.state) {
            StepState.Pending -> R.string.step_state_pending
            StepState.Running -> R.string.step_state_running
            StepState.Done -> R.string.step_state_done
            StepState.Failed -> R.string.step_state_failed
        },
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = Dimens.stepRowMinHeight)
            .semantics(mergeDescendants = true) {
                stateDescription = state
                if (step.state == StepState.Running) liveRegion = LiveRegionMode.Polite
            }
            .testTag(TestTags.progressStep(number)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Crossfade(
            targetState = step.state,
            animationSpec = tween(Motion.STEP_ICON),
            label = "stepIcon",
        ) { current ->
            Box(modifier = Modifier.size(Dimens.stepIconSlot), contentAlignment = Alignment.Center) {
                when (current) {
                    StepState.Pending -> Glyph(SnippetsIcon.RadioButtonUnchecked, contentDescription = null, tint = colors.outline)
                    StepState.Running -> CircularProgressIndicator(
                        modifier = Modifier.size(Dimens.spinnerStep),
                        color = colors.primary,
                        strokeWidth = Dimens.spinnerStroke,
                    )
                    StepState.Done -> Glyph(SnippetsIcon.Check, contentDescription = null, tint = SnippetsTheme.colors.success)
                    StepState.Failed -> Glyph(SnippetsIcon.Error, contentDescription = null, tint = colors.error)
                }
            }
        }
        Spacer(Modifier.width(Dimens.stepGap))
        Text(
            text = step.label,
            color = if (step.state == StepState.Pending) colors.onSurfaceVariant else colors.onSurface,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Preview(name = "Progress steps, light")
@Composable
private fun ProgressStepsPreviewLight() = PreviewSurface(darkTheme = false) { ProgressStepsPreviewContent() }

@Preview(name = "Progress steps, dark")
@Composable
private fun ProgressStepsPreviewDark() = PreviewSurface(darkTheme = true) { ProgressStepsPreviewContent() }

@Composable
private fun ProgressStepsPreviewContent() {
    ProgressSteps(
        steps = listOf(
            StepUi("Checking the repository", StepState.Done),
            StepUi("Creating the library…", StepState.Running),
            StepUi("Opening the library", StepState.Pending),
            StepUi("Connecting", StepState.Failed),
        ),
    )
}

package com.khm.snippets.android.feature.secure

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.RecoveryKeyPresenter
import com.khm.snippets.android.platform.ClipboardService
import com.khm.snippets.android.ui.components.FullScreenDialogHost
import com.khm.snippets.android.ui.components.SecretScreen
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.components.rememberSnippetsHaptics
import com.khm.snippets.android.ui.model.CodeFormat
import com.khm.snippets.android.ui.model.SecretScreenUi

/**
 * SEC-RECOVERY-KEY (`secure/recovery-key?mode=setup|add`, screens-secure.md §5), drawn over
 * everything while [RecoveryKeyPresenter] holds a request. The key exists only in that
 * application-scoped holder: never in the back stack or saved state, so after process death
 * there is nothing to restore and nothing was changed. `FLAG_SECURE` is on its window.
 */
@Composable
fun RecoveryKeyHost(presenter: RecoveryKeyPresenter, clipboard: ClipboardService) {
    val request by presenter.request.collectAsStateWithLifecycle()
    val current = request ?: return
    var copied by remember(current) { mutableStateOf(false) }
    val haptics = rememberSnippetsHaptics()
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    // Back and X cancel at once: nothing was stored yet (rule 3 of the template).
    FullScreenDialogHost(onDismissRequest = current::cancel, secure = true) { compact ->
        SecretScreen(
            ui = SecretScreenUi(
                routeTag = ROUTE_TAG,
                title = stringResource(R.string.recovery_key_title),
                heading = stringResource(R.string.recovery_key_heading),
                body = stringResource(R.string.recovery_key_body),
                code = current.key.symbols,
                doneTitle = stringResource(R.string.recovery_key_done),
                copyTitle = stringResource(R.string.action_copy),
                groupSize = current.key.groupSize,
                copiedMessage = if (copied) stringResource(R.string.recovery_key_copied) else null,
                canClose = true,
                closeDescription = stringResource(R.string.action_cancel),
                isHidden = !lifecycle.isAtLeast(Lifecycle.State.RESUMED),
            ),
            onCopy = {
                clipboard.copySecret(CodeFormat.grouped(current.key.symbols, current.key.groupSize), RECOVERY_KEY_CLIP_MILLIS)
                copied = true
                haptics.perform(SnippetsHaptic.SecretCopied)
            },
            onDone = current::acknowledge,
            onClose = current::cancel,
            compact = compact,
        )
    }
}

private const val ROUTE_TAG = "secure.recovery-key"

/** A copied vault recovery key is cleared after 5 minutes (DESIGN.md §11). */
private const val RECOVERY_KEY_CLIP_MILLIS = 5 * 60_000L

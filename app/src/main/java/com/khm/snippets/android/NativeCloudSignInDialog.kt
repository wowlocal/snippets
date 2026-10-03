package com.khm.snippets.android

import android.os.SystemClock
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal enum class NativeCloudSignInMode { SIGN_IN, CHANGE_ACCOUNT, RESUME }

internal enum class NativeCloudAuthAction { CREATE_ACCOUNT, SIGN_IN }

internal data class NativeCloudAuthRequest(
    val mode: NativeCloudSignInMode,
    val action: NativeCloudAuthAction,
)

internal const val ACCOUNT_KEY_SAVE_COPY =
    "This key is the only way to sign in to this account on another device. " +
        "Snippets can't recover it or send it to you. Store it in your password manager."

/** Bounds what the field holds; normalization still rejects anything over 64 UTF-8 bytes. */
private const val ACCOUNT_KEY_FIELD_MAX_CHARS = 256

@Composable
internal fun NativeCloudSignInDialog(
    action: NativeCloudAuthAction,
    createAccount: suspend () -> CloudSignInCompletion,
    signIn: suspend (String) -> CloudSignInCompletion,
    onDismiss: () -> Unit,
    onComplete: (CloudSignInCompletion) -> Unit,
) {
    // Deliberately not saveable: the account key is never serialized into activity state.
    var keyInput by remember { mutableStateOf("") }
    var keyVisible by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var retryAt by remember { mutableLongStateOf(0L) }
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(retryAt) {
        while (true) {
            now = SystemClock.elapsedRealtime()
            if (now >= retryAt) break
            delay(1_000)
        }
    }
    val retrySeconds = ((retryAt - now + 999).coerceAtLeast(0) / 1_000).toInt()
    val creating = action == NativeCloudAuthAction.CREATE_ACCOUNT
    fun submit() {
        if (busy || retrySeconds > 0) return
        val accountKey = if (creating) null else {
            // A local typing error is reported here and the key is never sent.
            NativeCloudAccountKey.normalize(keyInput) ?: run {
                error = nativeCloudSignInError("account_key_malformed")
                return
            }
        }
        busy = true
        error = null
        scope.launch {
            try {
                val completion = if (accountKey == null) createAccount() else signIn(accountKey)
                if (completion.succeeded || completion.needsLibrarySelection ||
                    completion.accountKey != null) {
                    keyInput = ""
                    onComplete(completion)
                } else {
                    error = nativeCloudSignInError(completion.errorCode ?: "sign_in_failed")
                    completion.retryAfterSeconds?.let {
                        retryAt = SystemClock.elapsedRealtime() + it * 1_000L
                    }
                }
            } finally { busy = false }
        }
    }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(if (creating) "Create a Snippets Cloud account" else "Sign In with Account Key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (creating) {
                    Text(
                        "Snippets Cloud creates a new account and shows its account key once. " +
                            "You'll need that key to sign in on another device.",
                    )
                } else {
                    Text("Enter the account key you saved when you created your account.")
                    OutlinedTextField(
                        value = keyInput,
                        onValueChange = {
                            keyInput = it.take(ACCOUNT_KEY_FIELD_MAX_CHARS)
                            error = null
                        },
                        label = { Text("Account key") },
                        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
                        // Password keyboards do not learn or suggest what is typed.
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.Characters,
                            keyboardType = KeyboardType.Password,
                            imeAction = ImeAction.Done,
                        ),
                        keyboardActions = KeyboardActions(onDone = { submit() }),
                        visualTransformation = if (keyVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        singleLine = true,
                        enabled = !busy,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    TextButton(onClick = { keyVisible = !keyVisible }) {
                        Text(if (keyVisible) "Hide key" else "Show key")
                    }
                }
                if (retrySeconds > 0) Text("Try again in ${retrySeconds}s")
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = !busy && retrySeconds == 0 && (creating || keyInput.isNotBlank()),
                onClick = ::submit,
            ) {
                Text(when {
                    busy -> "Please wait…"
                    creating -> "Create Account"
                    else -> "Sign In"
                })
            }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * Save Your Account Key after Create Account, or the authenticated Show Account Key.
 * The key is shown in display form, in monospaced selectable text.
 */
@Composable
internal fun NativeCloudAccountKeyDialog(
    presentation: AccountKeyPresentation,
    onCopy: (String) -> Unit,
    onDone: () -> Unit,
) {
    val displayForm = remember(presentation) {
        NativeCloudAccountKey.displayForm(presentation.accountKey)
    }
    val acknowledgement = presentation.requiresAcknowledgement
    AlertDialog(
        // A new key is acknowledged explicitly; it cannot be dismissed by accident.
        onDismissRequest = { if (!acknowledgement) onDone() },
        properties = DialogProperties(
            dismissOnBackPress = !acknowledgement,
            dismissOnClickOutside = !acknowledgement,
        ),
        title = { Text(if (acknowledgement) "Save Your Account Key" else "Your Account Key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(ACCOUNT_KEY_SAVE_COPY)
                SelectionContainer {
                    Text(
                        displayForm,
                        style = MaterialTheme.typography.titleMedium.copy(fontFamily = FontFamily.Monospace),
                    )
                }
                OutlinedButton(onClick = { onCopy(displayForm) }) { Text("Copy") }
            }
        },
        confirmButton = {
            Button(onClick = onDone) { Text(if (acknowledgement) "I've Saved It" else "Done") }
        },
    )
}

internal const val DEVICE_SIGNED_IN_ACCOUNT_KEY_COPY =
    "This device was signed in by another device. View the account key on a device that has it."

internal const val DEVICE_SIGN_IN_APPROVAL_COPY =
    "Sign in a new device to this account? It will also receive this library's key. " +
        "Continue only if this code matches the code on the new device."

internal const val DEVICE_SIGN_IN_APPROVED_COPY = "The new device is signed in."

/** Poll delay: about two seconds, honoring Retry-After and backing off on failures. */
internal fun deviceSignInPollDelayMillis(consecutiveFailures: Int, retryAfterSeconds: Int?): Long =
    retryAfterSeconds?.let { it.coerceIn(1, 3_600) * 1_000L }
        ?: if (consecutiveFailures <= 0) 2_000L
        else (2_000L shl consecutiveFailures.coerceAtMost(4)).coerceAtMost(30_000L)

/**
 * New device: shows the `snippets-device-sign-in` QR and copyable text with the pairing
 * confirmation code, counts down, and polls the claim endpoint until a final outcome.
 */
@Composable
internal fun NativeCloudDeviceSignInDialog(
    presentation: DeviceSignInPresentation,
    poll: suspend () -> DeviceSignInPoll,
    onCopy: (String) -> Unit,
    onCancel: () -> Unit,
    onFinished: (CloudSignInCompletion) -> Unit,
) {
    var nowSeconds by remember { mutableLongStateOf(System.currentTimeMillis() / 1_000) }
    var status by remember(presentation) { mutableStateOf<String?>(null) }
    LaunchedEffect(presentation) {
        while (true) {
            nowSeconds = System.currentTimeMillis() / 1_000
            if (nowSeconds >= presentation.expiresAtEpochSeconds) break
            delay(1_000)
        }
    }
    LaunchedEffect(presentation) {
        var failures = 0
        while (true) {
            when (val result = poll()) {
                DeviceSignInPoll.Pending -> {
                    failures = 0
                    status = null
                    delay(deviceSignInPollDelayMillis(0, null))
                }
                is DeviceSignInPoll.Finished -> {
                    onFinished(result.completion)
                    return@LaunchedEffect
                }
                is DeviceSignInPoll.Failed -> {
                    // A terminal failure removed the request; the account screen shows why.
                    if (result.terminal) return@LaunchedEffect
                    failures += 1
                    status = nativeCloudSignInError(result.errorCode)
                    delay(deviceSignInPollDelayMillis(failures, result.retryAfterSeconds))
                }
            }
        }
    }
    val remaining = (presentation.expiresAtEpochSeconds - nowSeconds).coerceAtLeast(0)
    AlertDialog(
        onDismissRequest = onCancel,
        properties = DialogProperties(dismissOnClickOutside = false),
        title = { Text("Sign In with Another Device") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "On a device that's already signed in, open Snippets Cloud and choose " +
                        "Scan a new device invitation, or paste the text below. Continue only " +
                        "if both devices show the same code.",
                )
                SnippetsQRCode(presentation.payload, "Device sign-in QR")
                Text(
                    "Code: ${presentation.confirmationCode}",
                    style = MaterialTheme.typography.titleMedium.copy(fontFamily = FontFamily.Monospace),
                )
                Text("Expires in %02d:%02d".format(remaining / 60, remaining % 60))
                SelectionContainer {
                    Text(
                        presentation.payload,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    )
                }
                OutlinedButton(onClick = { onCopy(presentation.payload) }) { Text("Copy") }
                Text("Waiting for approval…", color = MaterialTheme.colorScheme.primary)
                status?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

internal fun nativeCloudSignInError(code: String): String = when (code) {
    "account_key_malformed" -> "This isn't a valid account key. Check it for typos."
    "invalid_account_key" -> "That account key wasn't accepted. Check it and try again."
    "rate_limited" -> "Please wait before trying again."
    "device_sign_in_expired" -> "This sign-in request expired. Start again."
    "server_unavailable", "server_discovery_failed", "dependency_unavailable", "server_request_failed" ->
        "Couldn’t reach Snippets Cloud. Check your connection and try again."
    else -> cloudErrorPresentation(code, null).message
}

package com.khm.snippets.android

import android.os.SystemClock
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal enum class NativeCloudSignInMode { SIGN_IN, CHANGE_ACCOUNT, RESUME }

@Composable
internal fun NativeCloudSignInDialog(
    start: suspend (String) -> CloudEmailChallenge,
    verify: suspend (String, String) -> CloudSignInCompletion,
    onEditEmail: () -> Unit,
    onDismiss: () -> Unit,
    onComplete: (CloudSignInCompletion) -> Unit,
) {
    // Deliberately not saveable: email/code are never serialized into activity state.
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var challenge by remember { mutableStateOf<CloudEmailChallenge?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var resendAt by remember { mutableStateOf(0L) }
    var expiresAt by remember { mutableStateOf(0L) }
    var retryAt by remember { mutableStateOf(0L) }
    var now by remember { mutableStateOf(SystemClock.elapsedRealtime()) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(resendAt, expiresAt, retryAt) {
        while (true) {
            now = SystemClock.elapsedRealtime()
            if (now >= maxOf(resendAt, expiresAt, retryAt)) break
            delay(1_000)
        }
    }
    val resendSeconds = ((resendAt - now + 999).coerceAtLeast(0) / 1_000).toInt()
    val retrySeconds = ((retryAt - now + 999).coerceAtLeast(0) / 1_000).toInt()
    val expired = challenge != null && now >= expiresAt
    fun sendCode() {
        if (busy || resendSeconds > 0) return
        busy = true
        error = null
        scope.launch {
            try {
                val issued = start(email.trim())
                challenge = issued
                code = ""
                retryAt = 0
                now = SystemClock.elapsedRealtime()
                resendAt = now + issued.resendAfter * 1_000L
                expiresAt = now + issued.expiresIn * 1_000L
            } catch (failure: CloudAuthFailure) {
                error = nativeCloudSignInError(failure.code)
                failure.retryAfterSeconds?.let {
                    retryAt = SystemClock.elapsedRealtime() + it * 1_000L
                    resendAt = maxOf(resendAt, retryAt)
                }
            } finally { busy = false }
        }
    }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(if (challenge == null) "Sign in to Snippets Cloud" else "Check your email") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (challenge == null) {
                    Text("Enter your email address. We’ll send a one-time sign-in code.")
                    OutlinedTextField(
                        value = email,
                        onValueChange = { email = it.take(254); error = null },
                        label = { Text("Email") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        singleLine = true,
                        enabled = !busy,
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    Text("Enter the 6-digit code sent to ${email.trim()}.")
                    OutlinedTextField(
                        value = code,
                        onValueChange = { code = it.filter { c -> c in '0'..'9' }.take(6); error = null },
                        label = { Text("Code") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                        singleLine = true,
                        enabled = !busy && !expired,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (expired) Text("This code expired. Request a new code.")
                    TextButton(enabled = !busy && resendSeconds == 0, onClick = ::sendCode) {
                        Text(if (resendSeconds == 0) "Send a new code" else "Send again in ${resendSeconds}s")
                    }
                    TextButton(enabled = !busy, onClick = {
                        onEditEmail()
                        challenge = null
                        code = ""
                        error = null
                        expiresAt = 0
                        // Keep the cooldown when editing the address to avoid accidental retries.
                    }) { Text("Edit email") }
                }
                if (challenge == null && resendSeconds > 0) Text("Try again in ${resendSeconds}s")
                if (challenge != null && retrySeconds > 0) Text("Try again in ${retrySeconds}s")
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = !busy && if (challenge == null) email.trim().contains('@') && resendSeconds == 0
                    else code.length == 6 && !expired && retrySeconds == 0,
                onClick = {
                    val current = challenge
                    if (current == null) sendCode()
                    else if (!busy) {
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                val completion = verify(current.challengeID, code)
                                if (completion.succeeded || completion.needsLibrarySelection) onComplete(completion)
                                else {
                                    error = nativeCloudSignInError(completion.errorCode ?: "sign_in_failed")
                                    completion.retryAfterSeconds?.let {
                                        retryAt = SystemClock.elapsedRealtime() + it * 1_000L
                                        resendAt = maxOf(resendAt, retryAt)
                                    }
                                }
                            } finally { busy = false }
                        }
                    }
                },
            ) { Text(if (busy) "Please wait…" else if (challenge == null) "Send code" else "Sign in") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") } },
    )
}

internal fun nativeCloudSignInError(code: String): String = when (code) {
    "invalid_email" -> "Enter a valid email address."
    "invalid_code" -> "That code didn’t match. Check the email and try again."
    "code_expired", "authorization_session_missing" -> "This code expired. Request a new code."
    "too_many_attempts" -> "Too many incorrect attempts. Request a new code."
    "rate_limited" -> "Please wait before trying again."
    "server_unavailable", "server_discovery_failed", "dependency_unavailable", "server_request_failed" ->
        "Couldn’t reach Snippets Cloud. Check your connection and try again."
    else -> cloudErrorPresentation(code, null).message
}

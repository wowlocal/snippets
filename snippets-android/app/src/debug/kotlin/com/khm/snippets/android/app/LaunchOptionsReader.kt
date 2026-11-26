package com.khm.snippets.android.app

import android.content.Intent
import com.khm.snippets.android.platform.AuthResult

/**
 * Debug builds: reads the test and demo launch extras (screens-system.md §8).
 *
 * ```
 * adb shell am start -n com.khm.snippets.android.debug/com.khm.snippets.android.MainActivity \
 *     --es demo-seed standard --es ui-testing-auth cancel --ei ui-testing-secure-clip-seconds 5
 * ```
 */
object LaunchOptionsReader {
    const val EXTRA_DEMO_SEED = "demo-seed"
    const val EXTRA_RESET = "ui-testing-reset"
    const val EXTRA_AUTH = "ui-testing-auth"
    const val EXTRA_SECURE_CLIP_SECONDS = "ui-testing-secure-clip-seconds"

    fun read(intent: Intent?): LaunchOptions {
        if (intent == null) return LaunchOptions.Default
        return LaunchOptions(
            seed = if (intent.getStringExtra(EXTRA_DEMO_SEED) == DEMO_STANDARD) DemoLibrary.standard() else null,
            resetHints = intent.getBooleanExtra(EXTRA_RESET, false),
            authAnswer = when (intent.getStringExtra(EXTRA_AUTH)) {
                "approve" -> AuthResult.Success
                "cancel" -> AuthResult.Cancelled
                "fail" -> AuthResult.NotApproved
                else -> null
            },
            secureClipSeconds = intent.getIntExtra(EXTRA_SECURE_CLIP_SECONDS, 0).takeIf { it > 0 },
        )
    }

    private const val DEMO_STANDARD = "standard"
}

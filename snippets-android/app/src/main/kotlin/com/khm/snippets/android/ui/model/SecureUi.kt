package com.khm.snippets.android.ui.model

import androidx.compose.runtime.Immutable

/** Why the panel locked by itself during this editor visit. */
enum class LockReason { IdleTimeout, SessionExpired, LeftApp }

/** Why secure content is being withheld although it was authenticated. */
enum class ProtectedCause { ScreenRecording, UnprotectedDisplay }

/** Why this device cannot open the secure body at all. */
enum class UnavailableCause { NoScreenLock, GitVaultNotSetUp, VaultKeyMissing }

/**
 * State of the secure body panel (components.md §8). The plaintext exists only in [Revealed].
 * [stateName] is the root's `stateDescription`, for tests.
 */
@Immutable
sealed interface SecurePanelState {
    val stateName: String

    @Immutable
    data class Locked(val reason: LockReason? = null) : SecurePanelState {
        override val stateName: String get() = "locked"
    }

    @Immutable
    data object Unlocking : SecurePanelState {
        override val stateName: String get() = "unlocking"
    }

    /**
     * The body is on screen and editable. Hold this state in memory only: never in saved state,
     * logs or anything that outlives the editor.
     */
    @Immutable
    class Revealed(val body: String) : SecurePanelState {
        override val stateName: String get() = "revealed"
        override fun equals(other: Any?): Boolean = other is Revealed && other.body == body
        override fun hashCode(): Int = body.hashCode()

        /** Never prints the body. */
        override fun toString(): String = "Revealed(body=<hidden>)"
    }

    @Immutable
    data class Protected(val cause: ProtectedCause) : SecurePanelState {
        override val stateName: String get() = "protected"
    }

    @Immutable
    data class Unavailable(val cause: UnavailableCause) : SecurePanelState {
        override val stateName: String get() = "unavailable"
    }
}

/** How a secret is laid out and whether it can be selected (components.md §9). */
enum class SecretVariant {
    /** Recovery key, recovery code, account key, kit code: grouped `monoCode`, not selectable. */
    Code,

    /** Pairing or sign-in confirmation code: one line of `monoCodeLarge`, not copyable. */
    Comparison,

    /** SSH host key fingerprint: `SHA256:` then groups of 8, selectable. */
    Fingerprint,

    /** Device SSH public key: soft-wrapped, never truncated, selectable. */
    PublicKey,
}

/**
 * Content of a secret screen (components.md §14).
 *
 * @param routeTag Added to the root next to `secret.screen`, for example `git.code-show`.
 * @param code The raw symbols, without separators. Kept in a route-scoped holder by the caller.
 * @param groupSize Symbols per displayed group.
 * @param copiedMessage The line under Copy once the secret was copied, or null before that.
 * @param note Optional warning or note under the copy line.
 * @param canClose Shows the close button (only where cancelling is allowed).
 * @param closeDescription Content description of the close button, `Cancel` by default.
 * @param isHidden The app is not resumed: everything below the top bar is replaced.
 */
@Immutable
class SecretScreenUi(
    val routeTag: String,
    val title: String,
    val heading: String,
    val body: String,
    val code: String,
    val doneTitle: String,
    val copyTitle: String? = null,
    val groupSize: Int = 4,
    val copiedMessage: String? = null,
    val note: String? = null,
    val canClose: Boolean = false,
    val closeDescription: String? = null,
    val isHidden: Boolean = false,
) {
    /** Never prints the code. */
    override fun toString(): String = "SecretScreenUi(routeTag=$routeTag, code=<hidden>)"
}

/** State of the secure-copy countdown row (components.md §10). */
@Immutable
sealed interface CountdownUi {
    /**
     * A secure body is on the clipboard.
     *
     * @param name Display name of the copied entry.
     * @param deadlineMillis When the clip is cleared, on the clock the row is given
     *   (`SystemClock.elapsedRealtime()` by default). The deadline is real time, so the row
     *   survives recomposition and rotation.
     * @param totalMillis Lifetime of the clip; the bar drains over it.
     */
    @Immutable
    data class Running(
        val name: String,
        val deadlineMillis: Long,
        val totalMillis: Long = SECURE_CLIP_LIFETIME_MILLIS,
    ) : CountdownUi

    /** `Clipboard cleared.`, shown for 3 s before the row leaves. */
    @Immutable
    data object Cleared : CountdownUi

    companion object {
        /** A copied secure body stays on the clipboard for 60 seconds. */
        const val SECURE_CLIP_LIFETIME_MILLIS = 60_000L
    }
}

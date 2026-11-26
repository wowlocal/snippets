package com.khm.snippets.core.vault

/**
 * The ordering rules for showing a secure body on a protected surface
 * (`SecureCapturePresentationPolicy.swift`). Pure state, so the security-critical
 * transitions are testable without a window.
 *
 * On Android the protected surface is a window with `FLAG_SECURE`. The mapping:
 *
 * - [suppressesUnprotectedDrawing]: `FLAG_SECURE` must be set on the window.
 * - [permitsPlaintextInTextStorage]: the plaintext may be put into the view tree. Set the
 *   flag (call [arm]) before that, and clear the text before
 *   [resetAfterPlaintextWasCleared] lets the flag go.
 * - [rendersPlaintextPixels]: the text may actually be visible rather than redacted.
 *
 * A value type: every transition returns a new policy.
 *
 * Not ported from the same Swift file, because they describe macOS only:
 * `SecureHoverRevealPolicy` and `SecureHoverEditingPolicy` (reveal while the mouse
 * pointer is inside the editor) and `SecureCaptureFrameGeometry` (the pixel size of the
 * protected video layer). The iPhone equivalent of the reveal rules is
 * [SecureRevealPolicy].
 */
data class SecureCapturePresentationPolicy(val phase: Phase = Phase.ORDINARY) {

    enum class Phase {
        /** The platform draws normally. Ordinary snippets use only this phase. */
        ORDINARY,

        /** Unprotected drawing is suppressed and the protected surface shows a redaction. */
        PROTECTED_REDACTION,

        /** Unprotected drawing is suppressed and the protected surface may show plaintext. */
        PROTECTED_PLAINTEXT,

        /** Protection failed. Unprotected drawing stays suppressed and nothing is shown. */
        FAILED_CLOSED,
    }

    val suppressesUnprotectedDrawing: Boolean get() = phase != Phase.ORDINARY

    val permitsPlaintextInTextStorage: Boolean
        get() = phase == Phase.PROTECTED_REDACTION || phase == Phase.PROTECTED_PLAINTEXT

    val rendersPlaintextPixels: Boolean get() = phase == Phase.PROTECTED_PLAINTEXT

    val keepsProtectedLayerVisible: Boolean
        get() = phase == Phase.PROTECTED_REDACTION || phase == Phase.PROTECTED_PLAINTEXT

    /** Protection is in place. Always starts redacted. */
    fun arm(): SecureCapturePresentationPolicy = copy(phase = Phase.PROTECTED_REDACTION)

    /** Has no effect before [arm] and after [failClosed]. */
    fun setPlaintextPixelsVisible(visible: Boolean): SecureCapturePresentationPolicy {
        if (!permitsPlaintextInTextStorage) return this
        return copy(phase = if (visible) Phase.PROTECTED_PLAINTEXT else Phase.PROTECTED_REDACTION)
    }

    fun failClosed(): SecureCapturePresentationPolicy = copy(phase = Phase.FAILED_CLOSED)

    /**
     * Back to ordinary drawing. The caller must have removed the plaintext from the view
     * tree first; the policy cannot verify that, so the name states the precondition.
     */
    fun resetAfterPlaintextWasCleared(): SecureCapturePresentationPolicy = copy(phase = Phase.ORDINARY)

    enum class RebindStep { SUPPRESS_DRAWING, CLEAR_OLD_TEXT, REMOVE_PROTECTED_PRESENTATION, ASSIGN_ORDINARY_TEXT }

    companion object {
        /**
         * The order in which a view that showed a secure body is given an ordinary one:
         * the new text is assigned only after the old secure text is gone and ordinary
         * drawing is restored.
         */
        fun ordinaryRebindSteps(): List<RebindStep> = listOf(
            RebindStep.SUPPRESS_DRAWING,
            RebindStep.CLEAR_OLD_TEXT,
            RebindStep.REMOVE_PROTECTED_PRESENTATION,
            RebindStep.ASSIGN_ORDINARY_TEXT,
        )
    }
}

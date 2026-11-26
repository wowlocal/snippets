package com.khm.snippets.core.vault

import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `Tests/Core/SecureCapturePresentationPolicyTests.swift` (the capture suite; the hover
 * and frame-geometry suites test macOS-only types that are not ported),
 * `Tests/SecurePlaintextLeaseTests.swift`, and the policy tests of
 * `snippets-ios-tests/SecureSnippetRevealTests.swift` (the others drive `UITextView`).
 */
class SecurePoliciesTest {

    // SecureCapturePresentationPolicy

    /** "Plaintext pixels are impossible before protection is armed" */
    @Test fun plaintextRequiresArming() {
        val policy = SecureCapturePresentationPolicy().setPlaintextPixelsVisible(true)

        assertEquals(SecureCapturePresentationPolicy.Phase.ORDINARY, policy.phase)
        assertFalse(policy.suppressesUnprotectedDrawing)
        assertFalse(policy.permitsPlaintextInTextStorage)
        assertFalse(policy.rendersPlaintextPixels)
    }

    /** "Arming starts with protected redaction" */
    @Test fun armStartsRedacted() {
        val policy = SecureCapturePresentationPolicy().arm()

        assertEquals(SecureCapturePresentationPolicy.Phase.PROTECTED_REDACTION, policy.phase)
        assertTrue(policy.suppressesUnprotectedDrawing)
        assertTrue(policy.permitsPlaintextInTextStorage)
        assertTrue(policy.keepsProtectedLayerVisible)
        assertFalse(policy.rendersPlaintextPixels)
    }

    /** "Pixel visibility is independent from the armed lifetime" */
    @Test fun pixelVisibilityCanToggle() {
        val shown = SecureCapturePresentationPolicy().arm().setPlaintextPixelsVisible(true)
        assertEquals(SecureCapturePresentationPolicy.Phase.PROTECTED_PLAINTEXT, shown.phase)
        assertTrue(shown.suppressesUnprotectedDrawing)
        assertTrue(shown.rendersPlaintextPixels)

        val hidden = shown.setPlaintextPixelsVisible(false)
        assertEquals(SecureCapturePresentationPolicy.Phase.PROTECTED_REDACTION, hidden.phase)
        assertTrue(hidden.suppressesUnprotectedDrawing)
        assertTrue(hidden.keepsProtectedLayerVisible)
        assertFalse(hidden.rendersPlaintextPixels)
    }

    /** "Failure never falls back to AppKit drawing": on Android, never back to a window without FLAG_SECURE. */
    @Test fun failureIsClosed() {
        val failed = SecureCapturePresentationPolicy().arm().setPlaintextPixelsVisible(true).failClosed()

        assertEquals(SecureCapturePresentationPolicy.Phase.FAILED_CLOSED, failed.phase)
        assertTrue(failed.suppressesUnprotectedDrawing)
        assertFalse(failed.permitsPlaintextInTextStorage)
        assertFalse(failed.keepsProtectedLayerVisible)
        assertFalse(failed.rendersPlaintextPixels)

        assertEquals(SecureCapturePresentationPolicy.Phase.FAILED_CLOSED, failed.setPlaintextPixelsVisible(true).phase)
    }

    /** "Only explicit post-clear reset restores ordinary drawing" */
    @Test fun resetAfterClear() {
        val reset = SecureCapturePresentationPolicy().arm().failClosed().resetAfterPlaintextWasCleared()

        assertEquals(SecureCapturePresentationPolicy.Phase.ORDINARY, reset.phase)
        assertFalse(reset.suppressesUnprotectedDrawing)
    }

    /** "Ordinary rebind assigns its body only after secure teardown" */
    @Test fun ordinaryRebindOrdering() {
        assertEquals(
            listOf(
                SecureCapturePresentationPolicy.RebindStep.SUPPRESS_DRAWING,
                SecureCapturePresentationPolicy.RebindStep.CLEAR_OLD_TEXT,
                SecureCapturePresentationPolicy.RebindStep.REMOVE_PROTECTED_PRESENTATION,
                SecureCapturePresentationPolicy.RebindStep.ASSIGN_ORDINARY_TEXT,
            ),
            SecureCapturePresentationPolicy.ordinaryRebindSteps(),
        )
    }

    /** The rule the Android mapping rests on: plaintext may be in the view tree only while the window is protected. */
    @Test fun plaintextInTheViewTreeAlwaysImpliesAProtectedWindow() {
        var policy = SecureCapturePresentationPolicy()
        val steps: List<(SecureCapturePresentationPolicy) -> SecureCapturePresentationPolicy> = listOf(
            { it.setPlaintextPixelsVisible(true) }, { it.arm() }, { it.setPlaintextPixelsVisible(true) },
            { it.setPlaintextPixelsVisible(false) }, { it.failClosed() }, { it.setPlaintextPixelsVisible(true) },
            { it.resetAfterPlaintextWasCleared() }, { it.arm() }, { it.resetAfterPlaintextWasCleared() },
        )
        for (step in steps) {
            policy = step(policy)
            if (policy.permitsPlaintextInTextStorage || policy.rendersPlaintextPixels) {
                assertTrue(policy.suppressesUnprotectedDrawing, "plaintext was permitted in phase ${policy.phase} without protection")
            }
            if (policy.rendersPlaintextPixels) assertTrue(policy.permitsPlaintextInTextStorage)
        }
    }

    // SecurePlaintextLease

    @Test fun theLeaseOwnsTheBytesDecodesWhileLiveAndWipesIdempotently() {
        val source = "correct horse battery staple".toByteArray()
        val lease = SecurePlaintextLease.consuming(source)

        assertContentEquals(ByteArray(source.size), source, "construction must wipe the decrypted array it was given")
        assertFalse(lease.isWiped)
        assertEquals("correct horse battery staple", lease.makeUtf8String(), "the owned bytes decode while live")

        lease.wipe()
        assertTrue(lease.isWiped, "explicit wipe marks the lease consumed")
        assertNull(lease.makeUtf8String(), "wiped plaintext cannot be materialized")

        lease.wipe()
        assertTrue(lease.isWiped, "wipe is idempotent for layered cleanup")
        assertFalse(lease.toString().contains("correct"))
    }

    @Test fun aLeaseRefusesInvalidUtf8AndClosesLikeAResource() {
        val invalid = SecurePlaintextLease.consuming(byteArrayOf(0xC3.toByte(), 0x28))
        assertNull(invalid.makeUtf8String(), "invalid UTF-8 is refused")
        invalid.wipe()

        val empty = SecurePlaintextLease.consuming(ByteArray(0))
        assertEquals("", empty.makeUtf8String())

        val lease = SecurePlaintextLease.consuming("body".toByteArray())
        lease.use { assertEquals("body", it.makeUtf8String()) }
        assertTrue(lease.isWiped)
    }

    // SecureRevealPolicy (`SecureSnippetRevealTests`)

    private fun boundSecure(active: Boolean = true, captureInactive: Boolean = true, healthy: Boolean = true) =
        SecureRevealPolicy().apply { bindSecure(healthy, active, captureInactive) }

    /** `testAuthenticationStartsProtectedEditableRevealSession` */
    @Test fun testAuthenticationStartsProtectedEditableRevealSession() {
        val policy = boundSecure()
        assertEquals(SecureRevealPolicy.State.LOCKED, policy.state)
        assertFalse(policy.permitsTextMutation)

        val token = assertNotNull(policy.beginAuthentication())
        assertTrue(policy.isAuthenticating)
        assertNull(policy.beginAuthentication(), "a second request while one is in flight is refused")
        assertTrue(policy.authenticationSucceeded(token))
        assertEquals(SecureRevealPolicy.State.AUTHENTICATED_REDACTED, policy.state)
        assertFalse(policy.permitsTextMutation, "authenticated is not yet shown")

        assertEquals(SecureRevealTransition.REVEAL, policy.beginAuthenticatedReveal())
        assertTrue(policy.beginPlaintextPresentation())
        assertEquals(SecureRevealPolicy.State.PRESENTING_PLAINTEXT, policy.state)
        assertFalse(policy.permitsTextMutation)
        assertTrue(policy.confirmProtectedPlaintext())
        assertTrue(policy.isProtectedPlaintext)
        assertTrue(policy.permitsTextMutation)
        assertTrue(policy.isAuthenticated)
    }

    /** `testStaleAuthenticationCannotCrossRebind` */
    @Test fun testStaleAuthenticationCannotCrossRebind() {
        val policy = boundSecure()
        val stale = assertNotNull(policy.beginAuthentication())

        // The editor moved to another secure snippet while the prompt was up.
        policy.bindSecure(rendererIsHealthy = true, appAndSceneAreActive = true, sceneCaptureIsInactive = true)
        assertFalse(policy.authenticationSucceeded(stale))
        assertFalse(policy.authenticationFailed(stale))
        assertEquals(SecureRevealPolicy.State.LOCKED, policy.state)

        // A lock in between invalidates too, and so does an ordinary rebind.
        val second = assertNotNull(policy.beginAuthentication())
        assertEquals(SecureRevealTransition.NONE, policy.lock())
        assertFalse(policy.authenticationSucceeded(second))
        policy.bindOrdinary()
        assertFalse(policy.isSecure)
        assertNull(policy.beginAuthentication())
        assertEquals(SecureRevealTransition.NONE, policy.lock())
    }

    /** `testTransientBiometricDeactivationPreservesOnlyRedactedAuthentication` */
    @Test fun testTransientBiometricDeactivationPreservesOnlyRedactedAuthentication() {
        val policy = boundSecure()
        val token = assertNotNull(policy.beginAuthentication())
        // The system prompt deactivates the app; that must not cancel the prompt it belongs to.
        assertEquals(SecureRevealTransition.NONE, policy.setAppAndSceneAreActive(false))
        assertTrue(policy.authenticationSucceeded(token))
        assertEquals(SecureRevealPolicy.State.AUTHENTICATED_REDACTED, policy.state)

        // Still inactive: authenticated, but nothing may be shown.
        assertEquals(SecureRevealTransition.NONE, policy.beginAuthenticatedReveal())
        assertFalse(policy.beginPlaintextPresentation())

        assertEquals(SecureRevealTransition.NONE, policy.setAppAndSceneAreActive(true))
        assertEquals(SecureRevealTransition.REVEAL, policy.beginAuthenticatedReveal())
    }

    /** `testInactiveAppAndSceneCaptureImmediatelyRedactAndGateMutation` */
    @Test fun testInactiveAppAndSceneCaptureImmediatelyRedactAndGateMutation() {
        fun revealed() = boundSecure().apply {
            authenticationSucceeded(beginAuthentication()!!)
            beginPlaintextPresentation()
            confirmProtectedPlaintext()
        }

        val inactive = revealed()
        assertEquals(SecureRevealTransition.REDACT, inactive.setAppAndSceneAreActive(false))
        assertEquals(SecureRevealPolicy.State.AUTHENTICATED_REDACTED, inactive.state)
        assertFalse(inactive.permitsTextMutation)
        // Coming back does not reveal by itself.
        assertEquals(SecureRevealTransition.NONE, inactive.setAppAndSceneAreActive(true))
        assertEquals(SecureRevealPolicy.State.AUTHENTICATED_REDACTED, inactive.state)

        val captured = revealed()
        assertEquals(SecureRevealTransition.REDACT, captured.setSceneCaptureIsInactive(false))
        assertTrue(captured.isCaptureBlocked)
        assertFalse(captured.permitsTextMutation)
        assertEquals(SecureRevealTransition.NONE, captured.beginAuthenticatedReveal())

        val cancelled = revealed()
        assertEquals(SecureRevealTransition.REDACT, cancelled.cancelReveal())
        assertEquals(SecureRevealTransition.NONE, cancelled.cancelReveal())

        val locked = revealed()
        assertEquals(SecureRevealTransition.REDACT, locked.lock())
        assertEquals(SecureRevealPolicy.State.LOCKED, locked.state)
    }

    /** `testFocusLossWhilePresentationIsPendingForcesRedaction` */
    @Test fun testFocusLossWhilePresentationIsPendingForcesRedaction() {
        val policy = boundSecure()
        policy.authenticationSucceeded(policy.beginAuthentication()!!)
        assertTrue(policy.beginPlaintextPresentation())

        assertEquals(SecureRevealTransition.REDACT, policy.setAppAndSceneAreActive(false))
        assertFalse(policy.confirmProtectedPlaintext(), "a late confirmation must not reveal after focus was lost")
        assertEquals(SecureRevealPolicy.State.AUTHENTICATED_REDACTED, policy.state)
    }

    @Test fun anUnhealthyRendererFailsClosedAndStaysClosed() {
        val unhealthy = boundSecure(healthy = false)
        assertEquals(SecureRevealPolicy.State.FAILED_CLOSED, unhealthy.state)
        assertNull(unhealthy.beginAuthentication())
        assertEquals(SecureRevealTransition.NONE, unhealthy.lock())
        assertEquals(SecureRevealPolicy.State.FAILED_CLOSED, unhealthy.state)

        val policy = boundSecure()
        policy.authenticationSucceeded(policy.beginAuthentication()!!)
        policy.beginPlaintextPresentation()
        assertEquals(SecureRevealTransition.REDACT, policy.rendererFailed())
        assertEquals(SecureRevealPolicy.State.FAILED_CLOSED, policy.state)
        assertFalse(policy.confirmProtectedPlaintext())
        policy.revealAttemptFailed(vaultIsStillUnlocked = true)
        assertEquals(SecureRevealPolicy.State.FAILED_CLOSED, policy.state)

        val failedAttempt = boundSecure()
        failedAttempt.authenticationSucceeded(failedAttempt.beginAuthentication()!!)
        failedAttempt.revealAttemptFailed(vaultIsStillUnlocked = true)
        assertEquals(SecureRevealPolicy.State.LOCKED, failedAttempt.state)

        val ordinary = SecureRevealPolicy()
        assertEquals(SecureRevealTransition.NONE, ordinary.rendererFailed())
        assertEquals(SecureRevealPolicy.State.ORDINARY, ordinary.state)
        assertFalse(ordinary.isCaptureBlocked)
    }
}

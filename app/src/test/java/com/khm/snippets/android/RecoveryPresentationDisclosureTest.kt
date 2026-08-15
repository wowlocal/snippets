package com.khm.snippets.android

import org.junit.Assert.assertFalse
import org.junit.Test

class RecoveryPresentationDisclosureTest {
    @Test
    fun processWideLibraryStateCannotRetainRecoveryPresentation() {
        val retainedFields = LibraryState::class.java.declaredFields.map { it.name }.toSet()
        assertFalse("recoveryKitQRCode" in retainedFields)
        assertFalse("recoveryLongCode" in retainedFields)
        assertFalse("RECOVERY_KIT_READY" in CloudKeyStatus.entries.map { it.name })
    }
}

package com.khm.snippets.android

import com.khm.snippets.core.CoreInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class PlaceholderUnitTest {
    @Test
    fun appSeesCore() {
        assertEquals("Snippets", CoreInfo.NAME)
    }
}

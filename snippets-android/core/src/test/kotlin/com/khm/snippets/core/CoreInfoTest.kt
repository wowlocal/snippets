package com.khm.snippets.core

import kotlinx.coroutines.test.runTest
import org.junit.Test
import kotlin.test.assertEquals

class CoreInfoTest {
    @Test
    fun nameIsSnippets() = runTest {
        assertEquals("Snippets", CoreInfo.NAME)
    }
}

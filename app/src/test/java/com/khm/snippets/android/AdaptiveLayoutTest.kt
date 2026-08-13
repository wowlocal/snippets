package com.khm.snippets.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveLayoutTest {
    @Test
    fun twoPaneRequiresExpandedWidthAndNonCompactHeight() {
        assertTrue(shouldUseTwoPane(widthDp = 840f, heightDp = 480f))
        assertTrue(shouldUseTwoPane(widthDp = 1200f, heightDp = 800f))
        assertFalse(shouldUseTwoPane(widthDp = 839f, heightDp = 800f))
        assertFalse(shouldUseTwoPane(widthDp = 900f, heightDp = 411f))
    }
}

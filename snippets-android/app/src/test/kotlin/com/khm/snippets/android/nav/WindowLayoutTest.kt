package com.khm.snippets.android.nav

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WindowLayoutTest {
    @Test
    fun widthClassesAtTheirBoundaries() {
        assertEquals(WidthClass.Compact, windowLayoutOf(599.dp, 800.dp).widthClass)
        assertEquals(WidthClass.Medium, windowLayoutOf(600.dp, 800.dp).widthClass)
        assertEquals(WidthClass.Medium, windowLayoutOf(839.dp, 800.dp).widthClass)
        assertEquals(WidthClass.Expanded, windowLayoutOf(840.dp, 800.dp).widthClass)
        assertEquals(WidthClass.Expanded, windowLayoutOf(1199.dp, 800.dp).widthClass)
        assertEquals(WidthClass.Large, windowLayoutOf(1200.dp, 800.dp).widthClass)
    }

    @Test
    fun twoPanesNeedWidthAndHeight() {
        assertFalse(windowLayoutOf(839.dp, 800.dp).isTwoPane)
        assertTrue(windowLayoutOf(840.dp, 480.dp).isTwoPane)
        val short = windowLayoutOf(1200.dp, 479.dp)
        assertFalse(short.isTwoPane)
        assertTrue(short.isShort)
    }

    @Test
    fun paneWidthsAndMargins() {
        assertEquals(360.dp, windowLayoutOf(1000.dp, 800.dp).listPaneWidth)
        assertEquals(400.dp, windowLayoutOf(1300.dp, 800.dp).listPaneWidth)
        assertEquals(320.dp, windowLayoutOf(1000.dp, 800.dp).settingsPaneWidth)
        assertEquals(16.dp, windowLayoutOf(400.dp, 800.dp).horizontalMargin)
        assertEquals(24.dp, windowLayoutOf(700.dp, 800.dp).horizontalMargin)
    }
}

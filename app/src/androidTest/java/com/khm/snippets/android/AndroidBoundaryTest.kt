package com.khm.snippets.android

import android.content.ComponentName
import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONArray
import java.io.File

@RunWith(AndroidJUnit4::class)
class AndroidBoundaryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun encryptedStoreRoundTripsAndDoesNotWritePlaintext() {
        val name = "instrumentation-test.enc"
        val value = "private test snippet"
        val file = File(File(context.noBackupFilesDir, "SnippetsClone"), name)
        file.delete()

        val store = EncryptedStore(context)
        store.write(name, value)

        assertEquals(value, store.read(name))
        assertTrue(!file.readBytes().containsSubsequence(value.toByteArray()))
        file.delete()
    }

    @Test
    fun swiftCoreLoadsThroughGeneratedJniBoundary() {
        assertEquals(0, JSONArray(CoreBridge().canonicalize("[]")).length())
    }

    @Test
    fun manifestDeclaresNoKeyboardOrAccessibilityService() {
        val packageInfo = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.PackageInfoFlags.of(PackageManager.GET_SERVICES.toLong()))
        assertTrue(packageInfo.services.isNullOrEmpty())

        val processText = ComponentName(context, ProcessTextActivity::class.java)
        assertTrue(context.packageManager.getActivityInfo(processText, 0).exported)
    }

    @Test
    fun manifestUsesBrandedLauncherIconAndSplashTheme() {
        val applicationInfo = context.packageManager.getApplicationInfo(context.packageName, 0)
        assertEquals("com.khm.snippets.android:mipmap/ic_launcher",
            context.resources.getResourceName(applicationInfo.icon))

        val mainActivity = ComponentName(context, MainActivity::class.java)
        val activityInfo = context.packageManager.getActivityInfo(mainActivity, 0)
        assertEquals(R.style.Theme_Snippets_Starting, activityInfo.themeResource)
    }

    private fun ByteArray.containsSubsequence(needle: ByteArray): Boolean {
        if (needle.isEmpty()) return true
        return indices.any { start ->
            start + needle.size <= size && needle.indices.all { offset ->
                this[start + offset] == needle[offset]
            }
        }
    }
}

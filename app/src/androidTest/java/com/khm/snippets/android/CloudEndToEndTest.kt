package com.khm.snippets.android

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore

/**
 * Opt-in E2E test against a real HTTPS Snippets server and PostgreSQL database.
 *
 * Required runner arguments: snippetsServerUrl, snippetsAccessToken, snippetsSpaceId.
 * The test uploads encrypted data, destroys all app-local storage and its Android
 * Keystore wrapping key, then downloads and decrypts the record with the portable
 * sync key. It is skipped during normal connected-test runs.
 */
@RunWith(AndroidJUnit4::class)
class CloudEndToEndTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun uploadThenDownloadAfterCompleteLocalReset() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val serverURL = arguments.getString("snippetsServerUrl")
        val accessToken = arguments.getString("snippetsAccessToken")
        val spaceID = arguments.getString("snippetsSpaceId")
        assumeTrue(
            "Pass Snippets Cloud E2E runner arguments to enable this test",
            !serverURL.isNullOrBlank() && !accessToken.isNullOrBlank() && !spaceID.isNullOrBlank())
        val requiredServerURL = requireNotNull(serverURL)
        val requiredAccessToken = requireNotNull(accessToken)
        val requiredSpaceID = requireNotNull(spaceID)

        destroyLocalInstallationState()
        val keyBundle = portableKeyBundle()
        val uploaded = SnippetRepository.newSnippet().copy(
            name = "Android E2E",
            keyword = "android-e2e",
            content = PLAINTEXT_PROBE,
            tags = listOf("integration"),
            isPinned = true)

        val sender = SnippetRepository(context)
        sender.importPortableKeyBundle(keyBundle)
        assertNull(sender.state.value.errorCode)
        sender.save(uploaded)
        assertNull(sender.state.value.errorCode)
        sender.configureCloud(requiredServerURL, requiredAccessToken, requiredSpaceID)
        assertNull(sender.state.value.errorCode)
        sender.syncNow()
        assertNull(sender.state.value.errorCode)
        assertEquals("Synced", sender.state.value.syncLabel)
        assertEquals(PLAINTEXT_PROBE, sender.state.value.snippets.single().content)
        assertLocalFilesDoNotContain(PLAINTEXT_PROBE)

        // This models a fresh Android installation. Neither the encrypted files
        // nor the device-bound key survive; only the explicitly portable sync key does.
        destroyLocalInstallationState()
        val receiver = SnippetRepository(context)
        assertTrue(receiver.state.value.snippets.isEmpty())
        receiver.importPortableKeyBundle(keyBundle)
        assertNull(receiver.state.value.errorCode)
        receiver.configureCloud(requiredServerURL, requiredAccessToken, requiredSpaceID)
        assertNull(receiver.state.value.errorCode)
        receiver.syncNow()

        assertNull(receiver.state.value.errorCode)
        assertEquals("Synced", receiver.state.value.syncLabel)
        val downloaded = receiver.state.value.snippets.single()
        // Foundation's UUID Codable spelling is uppercase while java.util.UUID
        // emits lowercase; UUID identity is intentionally case-insensitive.
        assertEquals(uploaded.id.lowercase(), downloaded.id.lowercase())
        assertEquals(uploaded.name, downloaded.name)
        assertEquals(uploaded.keyword, downloaded.keyword)
        assertEquals(uploaded.content, downloaded.content)
        assertEquals(uploaded.tags, downloaded.tags)
        assertEquals(uploaded.isPinned, downloaded.isPinned)
        assertLocalFilesDoNotContain(PLAINTEXT_PROBE)
    }

    private fun destroyLocalInstallationState() {
        val root = File(context.noBackupFilesDir, "SnippetsClone")
        if (root.exists()) assertTrue(root.deleteRecursively())
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(LOCAL_KEY_ALIAS)) keyStore.deleteEntry(LOCAL_KEY_ALIAS)
        assertFalse(root.exists())
    }

    private fun assertLocalFilesDoNotContain(value: String) {
        val probe = value.toByteArray(Charsets.UTF_8)
        val root = File(context.noBackupFilesDir, "SnippetsClone")
        assertTrue(root.isDirectory)
        root.walkTopDown().filter(File::isFile).forEach { file ->
            assertFalse("plaintext found in ${file.name}", file.readBytes().containsSubsequence(probe))
        }
    }

    private fun portableKeyBundle(): String = JSONObject()
        .put("schemaVersion", 1)
        .put("scopeID", "sync-v1")
        .put("key", Base64.encodeToString(ByteArray(32) { 0x42 }, Base64.NO_WRAP))
        .put("salt", Base64.encodeToString(ByteArray(32) { 0x24 }, Base64.NO_WRAP))
        .toString()

    private fun ByteArray.containsSubsequence(needle: ByteArray): Boolean {
        if (needle.isEmpty()) return true
        return indices.any { start ->
            start + needle.size <= size && needle.indices.all { offset ->
                this[start + offset] == needle[offset]
            }
        }
    }

    private companion object {
        const val LOCAL_KEY_ALIAS = "com.khm.snippets.android.local-v1"
        const val PLAINTEXT_PROBE = "snippets-e2e-plaintext-probe-4f6c77f8"
    }
}

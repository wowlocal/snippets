package com.khm.snippets.android

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
 * Required runner arguments: snippetsServerUrl, snippetsAccessToken, snippetsSpaceId,
 * and snippetsPhase. The same disposable space is populated by macOS and iOS before
 * this test runs. Android must consume both, contribute its own record, survive complete
 * local resets, consume edits made by Apple clients, and publish an offline deletion
 * after a Local Only round trip. Chaos phases exercise an ambiguous acknowledgement and
 * stale-cursor recovery in the same instrumentation process that observed the failure.
 */
@RunWith(AndroidJUnit4::class)
class CloudEndToEndTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun participatesInCrossPlatformConvergence() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val serverURL = arguments.getString("snippetsServerUrl")
        val accessToken = arguments.getString("snippetsAccessToken")
        val spaceID = arguments.getString("snippetsSpaceId")
        val phase = arguments.getString("snippetsPhase")
        assumeTrue(
            "Pass Snippets Cloud E2E runner arguments to enable this test",
            !serverURL.isNullOrBlank() && !accessToken.isNullOrBlank() &&
                !spaceID.isNullOrBlank() && !phase.isNullOrBlank())
        val requiredServerURL = requireNotNull(serverURL)
        val requiredAccessToken = requireNotNull(accessToken)
        val requiredSpaceID = requireNotNull(spaceID)
        require(phase in setOf(
            "contribute",
            "verify",
            "delete",
            "delete-lost-ack",
            "chaos-stale-cursor",
            "verify-deletion",
        ))

        val keyBundle = portableKeyBundle()
        destroyLocalInstallationState()
        val client = freshClient(
            keyBundle, requiredServerURL, requiredAccessToken, requiredSpaceID)

        when (phase) {
            "contribute" -> {
                assertValues(client.state.value, mapOf(
                    "mac-e2e" to MAC_INITIAL,
                    "ios-e2e" to IOS_INITIAL))
                val uploaded = SnippetRepository.newSnippet().copy(
                    name = "Android E2E",
                    keyword = "android-e2e",
                    content = ANDROID_INITIAL,
                    tags = listOf("integration", "android"),
                    isPinned = true)
                client.save(uploaded)
                assertNull(client.state.value.errorCode)
                client.syncNow()
                assertSynced(client.state.value)
                assertValues(client.state.value, mapOf(
                    "mac-e2e" to MAC_INITIAL,
                    "ios-e2e" to IOS_INITIAL,
                    "android-e2e" to ANDROID_INITIAL))

                // This models a fresh Android installation. Neither encrypted files nor
                // the device-bound wrapping key survive; only the portable sync key does.
                destroyLocalInstallationState()
                val receiver = freshClient(
                    keyBundle, requiredServerURL, requiredAccessToken, requiredSpaceID)
                assertValues(receiver.state.value, mapOf(
                    "mac-e2e" to MAC_INITIAL,
                    "ios-e2e" to IOS_INITIAL,
                    "android-e2e" to ANDROID_INITIAL))
            }
            "verify" -> {
                assertValues(client.state.value, mapOf(
                    "mac-e2e" to MAC_FINAL,
                    "ios-e2e" to IOS_INITIAL,
                    "android-e2e" to ANDROID_FINAL))
            }
            "delete", "delete-lost-ack" -> {
                val beforeDeletion = mapOf(
                    "mac-e2e" to MAC_FINAL,
                    "ios-e2e" to IOS_INITIAL,
                    "android-e2e" to ANDROID_FINAL)
                assertValues(client.state.value, beforeDeletion)

                client.useDeviceOnly()
                assertEquals(SyncProvider.DEVICE, client.state.value.provider)
                assertEquals("On device", client.state.value.syncLabel)
                val iosRecord = client.state.value.snippets.single { it.keyword == "ios-e2e" }
                client.delete(iosRecord.id)
                assertNull(client.state.value.errorCode)
                assertLibraryValues(client.state.value, FINAL_WITHOUT_IOS)

                // The provider coordinates and agreed base survive Local Only. Returning to
                // the same HTTP scope must publish the offline deletion as a tombstone.
                client.configureCloud(requiredServerURL, requiredAccessToken, requiredSpaceID)
                client.syncNow()
                if (phase == "delete-lost-ack") {
                    assertEquals("dependency_unavailable", client.state.value.errorCode)
                    assertLibraryValues(client.state.value, FINAL_WITHOUT_IOS)
                    // The Nth-match rule is one-shot. Retry from the same repository that
                    // observed the ambiguous acknowledgement and confirm the server echo.
                    client.syncNow()
                    assertValues(client.state.value, FINAL_WITHOUT_IOS)
                    assertNotNull(client.configuration().cursor)
                } else {
                    assertValues(client.state.value, FINAL_WITHOUT_IOS)
                }

                destroyLocalInstallationState()
                val receiver = freshClient(
                    keyBundle, requiredServerURL, requiredAccessToken, requiredSpaceID)
                assertValues(receiver.state.value, FINAL_WITHOUT_IOS)
            }
            "chaos-stale-cursor" -> {
                val cursorBefore = requireNotNull(client.configuration().cursor)
                client.syncNow()
                assertValues(client.state.value, FINAL_WITHOUT_IOS)
                assertNotNull(client.configuration().cursor)
                assertEquals(cursorBefore, client.configuration().cursor)
            }
            "verify-deletion" -> assertValues(client.state.value, FINAL_WITHOUT_IOS)
            else -> error("validated above")
        }

        listOf(MAC_INITIAL, MAC_FINAL, IOS_INITIAL, ANDROID_INITIAL, ANDROID_FINAL)
            .forEach(::assertLocalFilesDoNotContain)
    }

    private suspend fun freshClient(
        keyBundle: String,
        serverURL: String,
        accessToken: String,
        spaceID: String,
    ): SnippetRepository {
        val client = SnippetRepository(context, snippetsCloudEnabled = true)
        assertTrue(client.state.value.snippets.isEmpty())
        client.importPortableKeyBundle(keyBundle)
        assertNull(client.state.value.errorCode)
        client.configureCloud(serverURL, accessToken, spaceID)
        assertNull(client.state.value.errorCode)
        client.syncNow()
        assertSynced(client.state.value)
        return client
    }

    private fun assertSynced(state: LibraryState) {
        assertNull(state.errorCode)
        assertEquals("Synced", state.syncLabel)
    }

    private fun assertValues(state: LibraryState, expected: Map<String, String>) {
        assertSynced(state)
        assertLibraryValues(state, expected)
    }

    private fun assertLibraryValues(state: LibraryState, expected: Map<String, String>) {
        assertEquals(expected.size, state.snippets.size)
        assertEquals(expected, state.snippets.associate { it.keyword to it.content })
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
        const val MAC_INITIAL = "snippets-macos-e2e-initial-8d134f53"
        const val MAC_FINAL = "snippets-macos-e2e-final-from-ios-8d134f53"
        const val IOS_INITIAL = "snippets-ios-e2e-initial-91a8c211"
        const val ANDROID_INITIAL = "snippets-android-e2e-initial-4f6c77f8"
        const val ANDROID_FINAL = "snippets-android-e2e-final-from-macos-4f6c77f8"
        val FINAL_WITHOUT_IOS = mapOf(
            "mac-e2e" to MAC_FINAL,
            "android-e2e" to ANDROID_FINAL)
    }
}

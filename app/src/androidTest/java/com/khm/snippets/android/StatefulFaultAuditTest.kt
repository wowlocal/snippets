package com.khm.snippets.android

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Opt-in only: the runner owns this disposable emulator installation. */
@RunWith(AndroidJUnit4::class)
class StatefulFaultAuditTest {
    @Test fun persistedOfflineAndCrashRecovery() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("snippetsStatefulAudit") == "disposable-emulator")
        check(android.os.Build.HARDWARE in setOf("ranchu", "goldfish"))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val stage = requireNotNull(args.getString("snippetsStage"))
        val server = requireNotNull(args.getString("snippetsServerUrl"))
        check(server == BuildConfig.SNIPPETS_CLOUD_URL)
        val client = SnippetRepository(context, snippetsCloudEnabled = true)
        client.search("") // Await encrypted-store initialization before any assertion.
        if (stage == "prepare" || stage == "join") {
            assertTrue(client.state.value.snippets.isEmpty())
            client.importPortableKeyBundle(JSONObject().put("schemaVersion",1).put("scopeID","sync-v1")
                .put("key",Base64.encodeToString(ByteArray(32){0x42},Base64.NO_WRAP))
                .put("salt",Base64.encodeToString(ByteArray(32){0x24},Base64.NO_WRAP)).toString())
        }
        client.configureCloud(server, requireNotNull(args.getString("snippetsAccessToken")), requireNotNull(args.getString("snippetsSpaceId")))
        assertNull(client.state.value.errorCode)
        if (stage == "prepare") {
            assertTrue(client.syncNow())
            assertEquals(3, client.state.value.snippets.size)
            client.useDeviceOnly()
            client.save(client.state.value.snippets.single { it.keyword == "race" }.copy(content="audit-concurrent-android"))
            client.save(client.state.value.snippets.single { it.keyword == "fields" }.copy(isEnabled=false))
            if (args.getString("snippetsKeepDeletion") != "1")
                client.delete(client.state.value.snippets.single { it.keyword == "delete-edit" }.id)
        } else if (stage == "switch") {
            client.save(client.state.value.snippets.single {it.keyword == "fields"}.copy(content="audit-account-switch-android"))
            val round = async { client.syncNow() }
            val signal = File(context.noBackupFilesDir,"switch-now")
            repeat(600) { if (!signal.exists()) delay(50) }
            assertTrue(signal.exists())
            val nextSpace = requireNotNull(args.getString("snippetsNextSpace"))
            val switching = async { client.configureCloud(server, requireNotNull(args.getString("snippetsNextToken")), nextSpace) }
            delay(300)
            assertFalse("account replacement must wait for the old sync mutex", switching.isCompleted)
            File(context.noBackupFilesDir,"switch-requested").writeText("ready")
            assertTrue(round.await())
            switching.await()
            assertEquals(nextSpace.lowercase(),client.configuration().spaceID.lowercase())
            File(context.noBackupFilesDir,"switch-completed").writeText("done")
        } else {
            if(stage == "crash") client.save(client.state.value.snippets.single {it.keyword == "fields"}.copy(content="audit-crash-android"))
            assertTrue(client.syncNow())
        }
        assertNull(client.state.value.errorCode)
        val snapshot = JSONArray()
        client.state.value.snippets.sortedBy { it.id.lowercase() }.forEach { s ->
            snapshot.put(JSONObject().put("id",s.id.lowercase()).put("keyword",s.keyword).put("name",s.name)
                .put("content",s.content).put("tags",JSONArray(s.tags.sorted())).put("isPinned",s.isPinned).put("isEnabled",s.isEnabled))
        }
        File(context.noBackupFilesDir,"audit-snapshot.json").writeText(snapshot.toString())
    }
}

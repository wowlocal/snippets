package com.khm.snippets.android

import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.io.File
import java.net.HttpURLConnection
import java.net.URI

/**
 * Opt-in real native UI/HTTPS/SMTP test, restricted to a disposable emulator.
 * A host-side Mailpit bridge writes each code into the app-private test inbox and
 * this test deletes it immediately. No code, token, email or key enters test output.
 */
class NativeCloudAuthEndToEndTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val arguments = InstrumentationRegistry.getArguments()
    private val context get() = instrumentation.targetContext
    private val compose = createAndroidComposeRule<MainActivity>()
    private val guard = object : ExternalResource() {
        override fun before() {
            assumeTrue(arguments.getString("snippetsNativeAuthE2E") == "disposable-emulator")
            assumeTrue(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish")
            require(BuildConfig.SNIPPETS_CLOUD_ENABLED)
            require(BuildConfig.SNIPPETS_CLOUD_URL == arguments.getString("snippetsServerUrl"))
            require(arguments.getString("snippetsTestEmail")?.endsWith("@ephemeral.test") == true)
            require(EncryptedStore(context).read("native-cloud-session.enc") == null) {
                "Native auth E2E requires an empty disposable installation"
            }
        }
    }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(guard).around(compose)

    @Test
    fun nativeEmailFlowSurvivesBadCodeResendRecreationRefreshAndLogout() {
        val email = requireNotNull(arguments.getString("snippetsTestEmail"))
        stage("opening_native_form")
        compose.onNodeWithContentDescription("Cloud settings").performClick()
        click("Open Snippets Cloud")
        click("Sign in to Snippets Cloud")
        waitForText("Email")
        assertFalse(File(context.filesDir, "native-auth-code-1.txt").exists())
        click("Cancel")
        click("Sign in to Snippets Cloud")
        emailField().performTextReplacement("invalid@")
        click("Send code")
        waitForText("Enter a valid email address.")
        emailField().performTextReplacement(email)
        stage("waiting_for_first_code")
        click("Send code")
        waitForText("Check your email")
        val firstCode = awaitCode(1)
        codeField().performTextReplacement(if (firstCode == "000000") "111111" else "000000")
        click("Sign in")
        waitForText("That code didn’t match. Check the email and try again.")
        stage("invalid_code_verified_waiting_resend")
        compose.waitUntil(80_000) {
            compose.onAllNodes(hasText("Send a new code") and hasClickAction() and isEnabled())
                .fetchSemanticsNodes().isNotEmpty()
        }
        click("Send a new code")
        val secondCode = awaitCode(2)
        codeField().performTextReplacement(secondCode)
        stage("verifying_code_and_bootstrap")
        click("Sign in")
        waitForButton("Change account", 90_000)
        assertTrue(compose.onAllNodes(hasText(email, substring = true)).fetchSemanticsNodes().isNotEmpty())

        // The genuine repository/bootstrap completed before inspecting its encrypted session.
        val store = EncryptedStore(context)
        val previous = JSONObject(requireNotNull(store.read("native-cloud-session.enc")))
        val previousToken = previous.getJSONObject("generation").getString("accessToken")
        val accountID = previous.getString("accountID")
        assertEquals(200, accountStatus(previousToken))
        stage("refresh_rotation")
        val rotated = runBlocking {
            CloudAuthenticator(context, store).freshAccessToken(BuildConfig.SNIPPETS_CLOUD_URL, forceRefresh = true)
        }
        assertTrue(rotated != previousToken)
        assertEquals(401, accountStatus(previousToken))
        assertEquals(200, accountStatus(rotated))
        val refreshed = JSONObject(requireNotNull(store.read("native-cloud-session.enc")))
        assertTrue(refreshed.getString("accountID") == accountID)
        assertTrue(refreshed.getString("email") == email)
        assertTrue(store.read("native-cloud-refresh-journal.enc") == null)

        stage("recreation")
        compose.activityRule.scenario.recreate()
        waitForButton("Change account", 30_000)
        assertTrue(compose.onAllNodes(hasText(email, substring = true)).fetchSemanticsNodes().isNotEmpty())
        stage("disconnecting")
        button("Disconnect this device").performScrollTo().performClick()
        compose.onNode(hasText("Disconnect this device") and hasClickAction() and hasAnyAncestor(isDialog()))
            .performClick()
        waitForButton("Sign in to Snippets Cloud", 60_000)
        assertTrue(store.read("native-cloud-session.enc") == null)
        assertTrue(store.read("native-cloud-revocation-journal.enc") == null)
        assertEquals(401, accountStatus(rotated))
        compose.activityRule.scenario.recreate()
        waitForButton("Sign in to Snippets Cloud", 30_000)
        stage("passed")
    }

    private fun button(text: String) = compose.onNode(hasText(text) and hasClickAction())
    private fun click(text: String) { waitForButton(text); button(text).performClick() }
    private fun emailField() = compose.onNode(hasText("Email") and hasSetTextAction())
    private fun codeField() = compose.onNode(hasText("Code") and hasSetTextAction())
    private fun waitForButton(text: String, timeout: Long = 30_000) {
        compose.waitUntil(timeout) {
            compose.onAllNodes(hasText(text) and hasClickAction() and isEnabled()).fetchSemanticsNodes().isNotEmpty()
        }
    }
    private fun waitForText(text: String) {
        compose.waitUntil(40_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
    }
    private fun awaitCode(index: Int): String {
        val file = File(context.filesDir, "native-auth-code-$index.txt")
        val deadline = System.nanoTime() + 40_000_000_000L
        while (!file.exists() && System.nanoTime() < deadline) Thread.sleep(100)
        require(file.exists()) { "Disposable mailbox bridge did not supply a code" }
        val code = file.readText().trim()
        check(file.delete())
        require(code.length == 6 && code.all { it in '0'..'9' }) { "Malformed disposable mailbox code" }
        return code
    }
    private fun stage(value: String) {
        File(context.filesDir, "native-auth-stage.txt").writeText(value)
    }
    private fun accountStatus(token: String): Int {
        val connection = URI(BuildConfig.SNIPPETS_CLOUD_URL + "/v2/spaces").toURL().openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Authorization", "Bearer $token")
            return connection.responseCode
        } finally { connection.disconnect() }
    }
}

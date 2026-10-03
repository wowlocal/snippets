package com.khm.snippets.android

import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.SecureRandom

/**
 * Opt-in real native UI/HTTPS account-key test, restricted to a disposable emulator.
 * It creates a throwaway account, so it needs no mailbox or credential fixture. The
 * account key, tokens and account ID stay in this process and never enter test output.
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
            require(EncryptedStore(context).read("native-cloud-session.enc") == null) {
                "Native auth E2E requires an empty disposable installation"
            }
        }
    }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(guard).around(compose)

    @Test
    fun accountKeyFlowSurvivesTyposCreationRecreationRefreshLogoutAndSignIn() {
        stage("opening_native_form")
        compose.onNodeWithContentDescription("Cloud settings").performClick()
        click("Open Snippets Cloud")
        click("Sign In with Account Key")
        waitForText("Account key")
        stage("local_typo_rejected")
        keyField().performTextReplacement("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ8")
        dialogButton("Sign In").performClick()
        waitForText("This isn't a valid account key. Check it for typos.")
        stage("unknown_key_rejected")
        keyField().performTextReplacement(NativeCloudAccountKey.displayForm(unknownWellFormedKey()))
        dialogButton("Sign In").performClick()
        waitForText("That account key wasn't accepted. Check it and try again.")
        dialogButton("Cancel").performClick()

        stage("creating_account_and_bootstrap")
        click("Create Account")
        dialogButton("Create Account").performClick()
        waitForText("Save Your Account Key", 90_000)
        val store = EncryptedStore(context)
        val created = JSONObject(requireNotNull(store.read("native-cloud-session.enc")))
        assertEquals(2, created.getInt("schemaVersion"))
        val accountKey = created.getString("accountKey")
        val accountID = created.getString("accountID")
        assertTrue(NativeCloudAccountKey.isCanonical(accountKey))
        assertTrue(compose.onAllNodes(hasText(NativeCloudAccountKey.displayForm(accountKey)))
            .fetchSemanticsNodes().isNotEmpty())
        dialogButton("I've Saved It").performClick()
        waitForButton("Change account", 30_000)
        assertTrue(compose.onAllNodes(hasText("Account ID ${nativeCloudAccountIDDisplay(accountID)}",
            substring = true)).fetchSemanticsNodes().isNotEmpty())

        val previousToken = created.getJSONObject("generation").getString("accessToken")
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
        assertTrue(refreshed.getString("accountKey") == accountKey)
        assertTrue(store.read("native-cloud-refresh-journal.enc") == null)

        stage("recreation")
        compose.activityRule.scenario.recreate()
        waitForButton("Change account", 30_000)
        stage("disconnecting")
        disconnect()
        assertTrue(store.read("native-cloud-session.enc") == null)
        assertTrue(store.read("native-cloud-revocation-journal.enc") == null)
        assertEquals(401, accountStatus(rotated))

        stage("signing_in_with_saved_key")
        click("Sign In with Account Key")
        // Users may paste the display form in any case; it is normalized before sending.
        keyField().performTextReplacement(" " + NativeCloudAccountKey.displayForm(accountKey).lowercase() + " ")
        dialogButton("Sign In").performClick()
        waitForButton("Change account", 90_000)
        val signedIn = JSONObject(requireNotNull(store.read("native-cloud-session.enc")))
        assertTrue(signedIn.getString("accountID") == accountID)
        assertTrue(signedIn.getString("accountKey") == accountKey)
        stage("disconnecting_again")
        disconnect()
        compose.activityRule.scenario.recreate()
        waitForButton("Sign In with Account Key", 30_000)
        stage("passed")
    }

    private fun disconnect() {
        button("Disconnect this device").performScrollTo().performClick()
        waitForText("You'll need your account key to sign in again.", substring = true)
        dialogButton("Disconnect this device").performClick()
        waitForButton("Sign In with Account Key", 60_000)
    }

    /** A correctly checked key that the server never issued. */
    private fun unknownWellFormedKey(): String {
        val random = SecureRandom()
        val body = String(CharArray(NativeCloudAccountKey.BODY_LENGTH) {
            NativeCloudAccountKey.ALPHABET[random.nextInt(NativeCloudAccountKey.ALPHABET.length)]
        })
        return body + NativeCloudAccountKey.check(body)
    }

    private fun button(text: String) = compose.onNode(
        hasText(text) and hasClickAction() and !hasAnyAncestor(isDialog()))
    private fun dialogButton(text: String) = compose.onNode(
        hasText(text) and hasClickAction() and hasAnyAncestor(isDialog()))
    private fun click(text: String) { waitForButton(text); button(text).performClick() }
    private fun keyField() = compose.onNode(hasText("Account key") and hasSetTextAction())
    private fun waitForButton(text: String, timeout: Long = 30_000) {
        compose.waitUntil(timeout) {
            compose.onAllNodes(hasText(text) and hasClickAction() and isEnabled()).fetchSemanticsNodes().isNotEmpty()
        }
    }
    private fun waitForText(text: String, timeout: Long = 40_000, substring: Boolean = false) {
        compose.waitUntil(timeout) {
            compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()
        }
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

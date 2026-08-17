package com.khm.snippets.android

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudConfigurationMigrationTest {
    @Test
    fun legacyV2ScopeWithoutServerInstanceFailsClosed() {
        val configuration = cloudConfiguration(JSONObject()
            .put("schemaVersion", 2)
            .put("provider", "SNIPPETS_CLOUD")
            .put("serverURL", "https://sync.example")
            .put("apiBaseURL", "https://sync.example/v2")
            .put("protocolMajor", 2)
            .put("accessToken", "")
            .put("spaceID", "11111111-1111-1111-1111-111111111111")
            .put("cursor", "old-cursor")
            .put("scopeBinding", "old-binding")
            .put("datasetGeneration", "22222222-2222-2222-2222-222222222222")
            .put("feedEpoch", "33333333-3333-3333-3333-333333333333")
            .toString())

        assertEquals(SyncProvider.SNIPPETS_CLOUD, configuration.provider)
        assertTrue(configuration.requiresServerInstanceReview())
    }

    @Test
    fun v3RoundTripRetainsServerInstancePin() {
        val original = CloudConfiguration(
            provider = SyncProvider.SNIPPETS_CLOUD,
            serverURL = "https://sync.example",
            apiBaseURL = "https://sync.example/v2",
            protocolMajor = 2,
            spaceID = "11111111-1111-1111-1111-111111111111",
            serverInstanceID = "44444444-4444-4444-4444-444444444444",
        )

        val json = original.toJSON()
        val decoded = cloudConfiguration(json)

        assertEquals(3, JSONObject(json).getInt("schemaVersion"))
        assertEquals(original, decoded)
        assertFalse(decoded.requiresServerInstanceReview())
    }
}

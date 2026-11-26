package com.khm.snippets.android.app

import com.khm.snippets.android.data.fake.SeedEntry
import com.khm.snippets.android.platform.AuthResult

/**
 * What a launch asks of the app beyond the defaults (screens-system.md §8). Only debug builds
 * read launch extras into this (`LaunchOptionsReader` in `src/debug`); a release build always
 * starts from [Default]: an empty library, no demo content.
 *
 * @param seed Entries the in-memory library starts with (`demo-seed=standard`).
 * @param resetHints Shows one-time tips again (`ui-testing-reset=true`).
 * @param authAnswer What the fake authenticator answers (`ui-testing-auth=approve|cancel|fail`).
 * @param secureClipSeconds Lifetime of a copied secure body (`ui-testing-secure-clip-seconds`).
 */
data class LaunchOptions(
    val seed: List<SeedEntry>? = null,
    val resetHints: Boolean = false,
    val authAnswer: AuthResult? = null,
    val secureClipSeconds: Int? = null,
) {
    companion object {
        val Default = LaunchOptions()
    }
}

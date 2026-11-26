package com.khm.snippets.android.feature.shared

import java.util.UUID

/** Routes and rows carry snippet ids as strings; a malformed one is treated as absent. */
fun String.toUuidOrNull(): UUID? = try {
    UUID.fromString(this)
} catch (_: IllegalArgumentException) {
    null
}

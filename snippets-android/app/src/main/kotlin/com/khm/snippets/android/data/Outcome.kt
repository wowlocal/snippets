package com.khm.snippets.android.data

/**
 * The result of a data-layer call that can fail. The data layer never throws for an expected
 * failure and never returns a message: [E] is a closed, typed error that the UI layer phrases.
 */
sealed interface Outcome<out T, out E> {
    data class Success<out T>(val value: T) : Outcome<T, Nothing>

    data class Failure<out E>(val error: E) : Outcome<Nothing, E>
}

/** The value of a success, or null. */
fun <T, E> Outcome<T, E>.valueOrNull(): T? = (this as? Outcome.Success)?.value

/** The error of a failure, or null. */
fun <T, E> Outcome<T, E>.errorOrNull(): E? = (this as? Outcome.Failure)?.error

/** A character range in a text, UTF-16 indices; [end] is exclusive. */
data class TextRange(val start: Int, val end: Int) {
    init {
        require(start in 0..end) { "invalid range $start..$end" }
    }
}

/**
 * A clock that only moves forward and keeps counting while the device sleeps, in milliseconds
 * from an arbitrary origin (`SystemClock.elapsedRealtime()` on a device). Deadlines of the vault
 * session and of timed clips are measured on it.
 */
fun interface MonotonicClock {
    fun nowMillis(): Long
}

package com.khm.snippets.core.clock

/**
 * Timestamps as the Swift model stores them: an IEEE-754 double of seconds since
 * 2001-01-01T00:00:00Z (`Date.timeIntervalSinceReferenceDate`).
 *
 * `createdAt` and `updatedAt` stay that raw double from the file to the envelope and
 * back. They are compared bit for bit and hashed through their decimal spelling, so they
 * must never pass through `Instant`, epoch milliseconds or a formatted date on the way.
 * The conversions here are for two purposes only: reading the system clock, and showing
 * a time to the user.
 */
object AppleTime {

    /** Seconds from 1970-01-01 to 2001-01-01, `Date.timeIntervalBetween1970AndReferenceDate`. */
    const val UNIX_EPOCH_OFFSET_SECONDS: Double = 978_307_200.0

    private const val UNIX_EPOCH_OFFSET_MILLIS: Long = 978_307_200_000L

    /** The largest wall reading an HLC holds: 48 bits of milliseconds. */
    const val MAX_HLC_MILLIS: Long = 0xFFFF_FFFF_FFFFL

    /** `Date().timeIntervalSinceReferenceDate`, at the millisecond resolution of the system clock. */
    fun now(): Double = fromUnixMillis(System.currentTimeMillis())

    /** Milliseconds since 1970 as seconds since 2001. Subtracting before dividing keeps the result the nearest double. */
    fun fromUnixMillis(unixMillis: Long): Double = (unixMillis - UNIX_EPOCH_OFFSET_MILLIS) / 1000.0

    /** `Date(timeIntervalSince1970:)`: one double subtraction, as Foundation does it. */
    fun fromUnixSeconds(unixSeconds: Double): Double = unixSeconds - UNIX_EPOCH_OFFSET_SECONDS

    /** `Date.timeIntervalSince1970`: one double addition, as Foundation does it. */
    fun unixSeconds(appleSeconds: Double): Double = appleSeconds + UNIX_EPOCH_OFFSET_SECONDS

    /**
     * `Date.millisecondsSince1970` in `HybridLogicalClock.swift`: the wall reading an HLC
     * takes from a timestamp. Not finite or not after 1970 gives 0; the product is cut
     * off at 48 bits and truncated toward zero, never rounded.
     */
    fun hlcMillis(appleSeconds: Double): Long {
        val seconds = unixSeconds(appleSeconds)
        if (!(seconds > 0.0) || seconds.isInfinite()) return 0L
        val millis = seconds * 1000.0
        return if (millis >= MAX_HLC_MILLIS.toDouble()) MAX_HLC_MILLIS else millis.toLong()
    }

    /**
     * Milliseconds since 1970 for showing [appleSeconds] to the user, rounded to the
     * nearest millisecond. Display only: the result must never be stored or compared in
     * place of the double. Not-a-number gives 0 and out-of-range values saturate.
     */
    fun displayUnixMillis(appleSeconds: Double): Long {
        val millis = unixSeconds(appleSeconds) * 1000.0
        if (millis.isNaN()) return 0L
        return Math.round(millis)
    }

    /** `System.currentTimeMillis()`, the default physical clock of [HlcGenerator] (`HLCGenerator.systemNowMs`). */
    fun systemUnixMillis(): Long = maxOf(0L, System.currentTimeMillis())
}

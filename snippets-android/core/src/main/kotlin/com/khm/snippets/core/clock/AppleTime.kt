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

    private val systemClock = AppleClock()

    /**
     * `Date().timeIntervalSinceReferenceDate`, from the process-wide [AppleClock]: the
     * wall clock with sub-millisecond resolution, and every call returns a value above
     * the one before it, on any thread. Records created in one loop therefore get
     * distinct, increasing times, as they do in Swift; with a millisecond clock they
     * would share one, and the display order would fall back to the ids.
     */
    fun now(): Double = systemClock.now()

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

/**
 * A source of "now" in seconds since 2001 that never repeats or goes back.
 *
 * `System.currentTimeMillis()` alone cannot tell two calls within a millisecond apart.
 * This reads the position inside the millisecond from the monotonic clock, anchored to
 * the wall clock: whenever the two disagree (the wall clock was set, or the monotonic
 * clock stood still while the device slept) it anchors again, so a reading always lies
 * within the wall clock's current millisecond. A reading that would not exceed the
 * previous one is replaced by the next double above it; after the wall clock is set
 * back, readings therefore creep forward until it has caught up.
 *
 * Thread-safe. The two sources are parameters so tests can drive time by hand.
 */
class AppleClock(
    private val wallMillis: () -> Long = System::currentTimeMillis,
    private val monotonicNanos: () -> Long = System::nanoTime,
) {
    private var anchorWallMillis = wallMillis()
    private var anchorNanos = monotonicNanos()
    private var last = Double.NEGATIVE_INFINITY

    @Synchronized
    fun now(): Double {
        val wall = wallMillis()
        val elapsed = monotonicNanos() - anchorNanos
        val drift = anchorWallMillis - wall
        // The first test keeps the multiplication from overflowing after a huge clock change.
        var withinMillisecond = if (drift < -MAX_DRIFT_MILLIS || drift > MAX_DRIFT_MILLIS) -1L else drift * NANOS_PER_MILLI + elapsed
        if (withinMillisecond < 0 || withinMillisecond >= NANOS_PER_MILLI) {
            anchorWallMillis = wall
            anchorNanos += elapsed
            withinMillisecond = 0
        }
        // Whole milliseconds since 2001 are exact in a double; the fraction is added to that.
        val reading = (wall - UNIX_EPOCH_OFFSET_MILLIS) / 1000.0 + withinMillisecond / 1e9
        last = if (reading > last) reading else Math.nextUp(last)
        return last
    }

    private companion object {
        const val NANOS_PER_MILLI = 1_000_000L
        const val MAX_DRIFT_MILLIS = 86_400_000L
        const val UNIX_EPOCH_OFFSET_MILLIS = 978_307_200_000L
    }
}

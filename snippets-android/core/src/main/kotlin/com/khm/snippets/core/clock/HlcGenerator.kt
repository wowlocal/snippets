package com.khm.snippets.core.clock

/**
 * Issues strictly increasing [Hlc]s for one device (`HLCGenerator`).
 *
 * Not thread-safe, as in Swift: one owner, one thread. Nothing here reads the system
 * clock directly; [physicalNowMs] is injected so tests can freeze it, step it back and
 * jump it forward.
 *
 * It starts from the later of [persisted] and the wall clock at counter 0, so the first
 * [send] at an unchanged wall clock carries counter 1. Journal clocks depend on that.
 *
 * Swift also has `observe(_:)` with a 24-hour drift limit and a rejection counter. No
 * production code calls it, so it is not ported.
 *
 * @param physicalNowMs milliseconds since 1970, read as unsigned like Swift's `UInt64`.
 */
class HlcGenerator(
    device: String,
    persisted: Hlc? = null,
    var physicalNowMs: () -> Long = AppleTime::systemUnixMillis,
) {

    /** The device every reading is issued for, normalized. */
    val device: String = Hlc.normalizedDevice(device)

    /** The highest reading issued so far, or the starting point. */
    var last: Hlc
        private set

    init {
        // A backwards clock correction across a restart must not reissue a reading.
        val now = Hlc.of(physicalNowMs(), 0, this.device)
        last = if (persisted != null && persisted > now) persisted else now
    }

    /** The next reading for a local change. */
    fun send(): Hlc = sendAtLeast(physicalNowMs())

    /** `send(atLeast:)`: as [send], with a wall reading of at least [floorMs] (unsigned). */
    fun sendAtLeast(floorMs: Long): Hlc {
        val now = physicalNowMs()
        val wall = if (java.lang.Long.compareUnsigned(now, floorMs) >= 0) now else floorMs
        last = when {
            java.lang.Long.compareUnsigned(wall, last.wallMs) > 0 -> Hlc.of(wall, 0, device)
            // The counter is full for this millisecond: carry into the wall reading
            // instead of wrapping back to a value already issued.
            last.counter == Hlc.MAX_COUNTER -> Hlc.of(last.wallMs + 1, 0, device)
            else -> Hlc.of(last.wallMs, last.counter + 1, device)
        }
        return last
    }

    /**
     * Stamps a local edit strictly above the record's own ancestor. Undo restores an
     * older [updatedAt], and a reading taken from it alone would lose to the remote copy
     * of the change being undone.
     *
     * @param updatedAt seconds since 2001, as the model stores it.
     */
    fun stamp(updatedAt: Double, baseHlc: Hlc?): Hlc {
        val fromRecord = AppleTime.hlcMillis(updatedAt)
        val aboveBase = (baseHlc?.wallMs ?: 0L) + 1
        return sendAtLeast(maxOf(fromRecord, aboveBase))
    }
}

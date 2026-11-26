package com.khm.snippets.android.testing

import com.khm.snippets.android.data.MonotonicClock
import com.khm.snippets.android.data.core.CoreSnippetResolver
import com.khm.snippets.android.data.fake.SeedEntry
import com.khm.snippets.android.platform.ClipClearScheduler
import com.khm.snippets.android.platform.ClipOwnership
import com.khm.snippets.android.platform.ClipToken
import com.khm.snippets.android.platform.SnippetClipboard
import com.khm.snippets.android.platform.TimeFormatter
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.placeholders.JvmDateRenderer
import kotlinx.coroutines.test.TestCoroutineScheduler
import java.time.ZoneId
import java.util.Locale
import java.util.UUID

/** An in-memory clipboard. Every write gets a new timestamp; [readable] simulates the background. */
class FakeClipboard : SnippetClipboard {
    var text: String? = null
    var sensitive = false
    var readable = true
    var reads = 0
        private set
    var clears = 0
        private set
    private var timestamp = 0L
    private var current = -1L
    private val listeners = ArrayList<() -> Unit>()

    override fun readText(): String? {
        reads += 1
        return if (readable) text else null
    }

    override fun write(text: String, sensitive: Boolean): ClipToken {
        this.text = text
        this.sensitive = sensitive
        current = ++timestamp
        listeners.toList().forEach { it() }
        return ClipToken(current)
    }

    /** Another app replaces the clip. */
    fun replaceFromOutside(text: String) {
        this.text = text
        sensitive = false
        current = ++timestamp
        listeners.toList().forEach { it() }
    }

    override fun ownership(token: ClipToken): ClipOwnership = when {
        !readable -> ClipOwnership.Unknown
        token.timestamp == current -> ClipOwnership.Ours
        else -> ClipOwnership.Replaced
    }

    override fun clear() {
        clears += 1
        text = null
        current = ++timestamp
    }

    override fun addChangeListener(listener: () -> Unit): AutoCloseable {
        listeners += listener
        return AutoCloseable { listeners -= listener }
    }
}

/** Records alarm requests of the clipboard backstop. */
class RecordingScheduler : ClipClearScheduler {
    val scheduled = ArrayList<Pair<ClipToken, Long>>()
    var cancels = 0
        private set

    /** An alarm is set and was not cancelled since. */
    var active = false
        private set

    override fun schedule(token: ClipToken, atElapsedMillis: Long) {
        scheduled += token to atElapsedMillis
        active = true
    }

    override fun cancel() {
        cancels += 1
        active = false
    }
}

/** Deterministic texts: `t:<seconds>`, `d:<seconds>`. */
class FakeTimeFormatter(var today: Boolean = true) : TimeFormatter {
    override fun rowTime(appleSeconds: Double): String = "row:${appleSeconds.toLong()}"
    override fun shortTime(appleSeconds: Double): String = "t:${appleSeconds.toLong()}"
    override fun mediumDate(appleSeconds: Double): String = "d:${appleSeconds.toLong()}"
    override fun isToday(appleSeconds: Double): Boolean = today
}

/** A monotonic clock driven by the virtual time of a test scheduler. */
fun TestCoroutineScheduler.monotonicClock(): MonotonicClock = MonotonicClock { currentTime }

fun resolver(): CoreSnippetResolver {
    val renderer = JvmDateRenderer(Locale.US, ZoneId.of("UTC"))
    // 2026-01-31T23:30:15Z in seconds since 2001.
    return CoreSnippetResolver(renderer = { renderer }, now = { 1_769_902_215.0 - 978_307_200.0 })
}

/** A fixed id for test entry [number]. */
fun id(number: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012d".format(number))

/** An ordinary snippet created at [created] (seconds since 2001); larger is newer. */
fun snippet(
    number: Int,
    name: String = "Entry $number",
    keyword: String = "",
    content: String = "",
    tags: List<String> = emptyList(),
    enabled: Boolean = true,
    pinned: Boolean = false,
    created: Double = number.toDouble(),
) = Snippet(
    id = id(number),
    name = name,
    keyword = keyword,
    content = content,
    tags = tags,
    isEnabled = enabled,
    isPinned = pinned,
    createdAt = created,
    updatedAt = created,
)

fun seed(snippet: Snippet, secureBody: String? = null) = SeedEntry(snippet, secureBody)

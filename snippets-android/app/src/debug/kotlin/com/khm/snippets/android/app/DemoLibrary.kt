package com.khm.snippets.android.app

import com.khm.snippets.android.data.fake.SeedEntry
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.model.Snippet
import java.util.UUID

/**
 * The fictional demo library (`demo-seed=standard`, debug builds only). Ids are fixed, so a
 * back stack restored after process death finds its entries again; times are relative to now,
 * so the rows show today, yesterday, a weekday and a date.
 */
object DemoLibrary {
    private const val HOUR = 3_600.0
    private const val DAY = 24 * HOUR

    fun standard(now: Double = AppleTime.now()): List<SeedEntry> = listOf(
        entry(1, "Meeting room", "meet", "https://meet.example.com/design-review", listOf("work", "links"), now - 0.4 * HOUR, pinned = true),
        entry(2, "Project brief", "brief", PROJECT_BRIEF, listOf("work", "notes"), now - 2 * DAY, pinned = true),
        entry(3, "Meeting notes", "notes", MEETING_NOTES, listOf("work", "notes"), now - 0.2 * HOUR),
        SeedEntry(
            snippet = snippet(4, "Atlas API token", "atlas-token", "", listOf("work", "tokens"), now - 1 * DAY),
            secureBody = "sk-live-9f3c2a7e41b8d6c0e5",
        ),
        entry(5, "Quick reply", "reply", QUICK_REPLY, emptyList(), now - 3 * DAY),
        entry(6, "Travel checklist", "travel", TRAVEL, listOf("travel", "personal"), now - 4 * DAY),
        entry(7, "Contact details", "sig", CONTACT, listOf("personal"), now - 9 * DAY),
        entry(8, "Home address", "addr", "221 Example Street\nSpringfield 01234", listOf("personal"), now - 15 * DAY),
        entry(9, "Team dashboard", "dash", "https://dashboard.example.com/team", listOf("work", "links"), now - 30 * DAY, enabled = false),
    )

    /** The id of demo entry [number] (1 to 9). */
    fun id(number: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012d".format(number))

    private fun entry(
        number: Int,
        name: String,
        keyword: String,
        content: String,
        tags: List<String>,
        created: Double,
        pinned: Boolean = false,
        enabled: Boolean = true,
    ) = SeedEntry(snippet(number, name, keyword, content, tags, created, pinned, enabled))

    private fun snippet(
        number: Int,
        name: String,
        keyword: String,
        content: String,
        tags: List<String>,
        created: Double,
        pinned: Boolean = false,
        enabled: Boolean = true,
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

    private const val PROJECT_BRIEF = "PROJECT ATLAS\nGoal: ship the public beta.\nOwner: Design team\nReview: every Thursday"
    private const val MEETING_NOTES = "Meeting notes — {date:yyyy-MM-dd}\n\nAgenda\n- Status\n- Risks\n\nAction items\n- "
    private const val QUICK_REPLY = "Thanks for reaching out. I will take a look and get back to you soon."
    private const val TRAVEL = "Passport\nCharger and adapter\nBoarding pass\nHeadphones"
    private const val CONTACT = "Alex Example\nalex@example.com\n+1 555 0100"
}

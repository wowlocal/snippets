# Design research: the library and the editor

Scope: the snippet list (home), search, tag filtering, copy feedback, gestures, creation, the editor, empty states and the large-screen list-detail layout for the Snippets Android rebuild (Kotlin, Jetpack Compose, Material 3, minSdk 28, target 36).

Source: Mobbin, searched through its MCP tools on 2026-11-25. Mobbin only offers `ios` and `web` platforms, so every mobile reference below is an iPhone screen. Section 3 translates the findings into Android and Material 3 terms; nothing here is a screenshot of an Android app. Every screen link goes to the screen on Mobbin; every description says what is visible in the image, not what the metadata claims.

Brand baseline (from `README.md` and `docs/images/`): dark, calm, text-first. The iPhone library row is three lines (name + time, `\keyword · body preview`, coloured tag chips) with a bottom bar of filter, search field and "+". The iPad uses a sidebar list (two-line rows, a green enabled dot, coloured tag dots, keyword at the trailing edge) beside a form-style editor with a monospace body, a resolved-placeholder preview and a token field for tags.

---

## 1. Method

42 searches: 34 `search_screens` on iOS, 3 `search_screens` on web, 5 `search_flows` on iOS. All used `output_destination: "code"` and the same task intent. Result limits were 6 to 10 screens (2 to 3 flows) per search to keep every image inspectable.

| # | Tool / platform | Query | What came back |
|---|---|---|---|
| 1 | screens / ios | password manager app item list screen | No dedicated password manager. Browser password lists (Google, Opera), Obsidian's Keychain, passkey lists. Partly useful. |
| 2 | screens / ios | notes app list of notes with tags and pinned notes | Apple Notes, Craft, Pocket, Reminders, Cursor, Raycast Notes, Wispr Flow, Granola. Strong. |
| 3 | screens / ios | bookmark manager app saved links list | Browser bookmark folders and news "saved" lists. No Raindrop, Instapaper or similar. Weak. |
| 4 | screens / ios | 1Password items list | Eight 1Password screens: list, grouping, category filter, sort, toasts. Strong. |
| 5 | screens / ios | Bitwarden vault items list | Dead end: Bitwarden is not in the results. Got Google passwords again, a Trust Wallet asset picker and Apple Maps Saved Places (both useful for row anatomy). |
| 6 | screens / ios | Proton Pass vault list of logins and notes | Dead end on iOS. One CLEAR vault card with masked fields and copy icons. |
| 7 | screens / ios | 1Password item detail screen with copy field and reveal password | Six 1Password detail states. Strong. |
| 8 | screens / ios | copied to clipboard confirmation toast | Ten different copy confirmations. Strong. |
| 9 | screens / ios | text snippets or text replacement shortcuts list with abbreviation | Wispr Flow Snippets, Quo Snippets, OpenPhone Snippets, plus unrelated "shortcuts" lists. Useful. |
| 10 | screens / ios | Raycast snippets list | Zero results. |
| 11 | screens / ios | notes app search results with matching text highlighted | Evernote, Otter, Apple Books, Substack, monday.com, Slack. Strong. |
| 12 | screens / ios | search screen no results empty state in a notes or productivity app | Evernote, ClickUp, Discord, Bolt Food, stoic, Upwork. Strong. |
| 13 | screens / ios | list filtered by multiple tags with horizontal filter chip row | Mostly chip-cloud pickers (Tinder, Oura, Depop, Agoda), not a scrolling filter row above a list. Partly useful. |
| 14 | screens / ios | filter bottom sheet with multi-select tags and item counts | Commerce and travel filter sheets with live counts. Strong for mechanics, wrong domain. |
| 15 | screens / ios | Bear notes tags sidebar and note list | Bear drawer, note list, tag context menu. Useful. |
| 16 | screens / ios | list row swipe actions revealed pin and delete in notes app | Swipe-to-delete in several apps, Notion Mail's swipe settings. No pin-by-swipe in a notes app. Partly useful. |
| 17 | screens / ios | long press context menu on a note with pin, duplicate, copy, delete | Overflow menus and action sheets (Apple Notes, Evernote, Raycast, Obsidian, Substack), not long-press previews. Useful. |
| 18 | screens / ios | multi-select mode in a list with bulk actions toolbar | Matter, Todoist, Yazio, Shopify, Apple Wallet. Strong. |
| 19 | screens / ios | item deleted snackbar with undo button | Medium, CVS, Spotify, Google Photos, Quo, Meta AI, Speechify. Strong. |
| 20 | screens / ios | paste from clipboard suggestion prompt to add a link or item | Paste buttons inside fields. No proactive "create from clipboard" prompt was found. Partly useful. |
| 21 | screens / ios | quick add bottom sheet to create a new note or item with title and text fields | ChatGPT, Tripadvisor, Cosmos, ClickUp, Mercury. Useful. |
| 22 | screens / ios | add tags input field with removable tag chips and suggestions while typing | Oura, Upwork, Pinterest, Quizlet, Alta, mymind, LinkedIn. Strong. |
| 23 | screens / ios | discard unsaved changes confirmation dialog when leaving editor | GoPro Quik, Givingli, Notion Mail, Universe, Gojek, 5 Minute Journal. Strong, mostly as warnings. |
| 24 | screens / ios | 1Password edit item screen with fields, tags and notes | Eight edit and new-item states. Strong. The tags field itself is not in any returned frame. |
| 25 | screens / ios | empty state for a notes or library app with no items yet and a create button | ChatGPT, Claude, Bluesky, Cherrypick, Edits, [untitled]. Strong. |
| 26 | screens / ios | code snippet viewer with monospace text and copy button | Linear, GitHub, Craft, Perplexity, Gemini, Cursor. Useful. |
| 27 | screens / ios | API keys or access tokens list with masked secret and copy button | Matter API token, Finch encryption key, Posh PINs, Bluesky app passwords. Useful. |
| 28 | screens / ios | search screen showing recent searches before typing | Weverse, Fabric, Deepstash, Badoo, Meta AI. Useful. |
| 29 | screens / ios | note editor showing saved status or last edited time with title and body | Dead end for autosave indicators: only modal note forms with Cancel/Save. |
| 30 | screens / ios | locked note or hidden content requiring Face ID to view | Apple Photos Hidden, CLEAR, Google Photos. The rest were biometric enrolment promos. Partly useful. |
| 31 | screens / ios | Obsidian file list and search with tags | Obsidian search, tag view, view switcher. Strong. |
| 32 | screens / ios | welcome screen offering to continue without an account or sign in to sync | Obsidian is the one relevant hit; the rest are retail "continue as guest" screens. |
| 33 | screens / ios | edit item form with switch toggles and metadata rows below a text field | SoundCloud, GitHub, Alta, Shopify. Useful. |
| 34 | screens / ios | copy button showing inline copied checkmark state after tapping | Phantom is the one true inline example; others repeat toasts. |
| 35 | screens / web | notes app three-pane layout with sidebar, note list and editor | Evernote, Obvious, Lightfield, Gemini Notebook. Useful. |
| 36 | screens / web | password manager web vault item list with detail pane | 1Password, Proton Pass, NordPass, Cloaked, Link. Strong. |
| 37 | screens / web | bookmark manager with tag filters and counts in sidebar | Craft "All Tags", Dovetail, Fabric tags, 1Password. No Raindrop. Partly useful. |
| 38 | flows / ios | password manager creating a new item | Opera and Muse add-password flows. |
| 39 | flows / ios | notes app searching notes | Wispr Flow, Apple Notes, Granola. Strong. |
| 40 | flows / ios | notes app pinning a note | Apple Notes, Evernote, Perplexity. |
| 41 | flows / ios | notes app deleting a note | Apple Notes, Opera, Udemy. |
| 42 | flows / ios | adding tags to a note | Obsidian inline tag, Apple Notes bulk tag sheet. |

Gaps to keep in mind when weighing the evidence:

- Not found at all on iOS: Bitwarden, Proton Pass (web only), Dashlane, Raindrop, Instapaper, Google Keep, Notion's page list, any clipboard manager, any dedicated text expander, Raycast Snippets. Password-manager conclusions rest on 1Password (iOS and web), Proton Pass and NordPass (web).
- No screen showed an autosave indicator, a live preview of templated text, a "create from clipboard" prompt, or an Android-style contextual selection bar. Recommendations for those come from the current Apple apps and platform guidance, and are marked as such.
- Flow results list screen ids without per-screen links, so flows are cited by flow link.

---

## 2. Pattern findings

### 2.1 Dense list and home screens

What the best apps do: a fixed, text-only row of two lines. Line 1 is the name; line 2 is one secondary fact that disambiguates (username, first line of content, edit time). Leading icons exist only where the content has a real identity (favicons). Sections carry state ("Pinned", date groups, alphabet) instead of per-row badges, and a quiet count closes the list.

- [1Password, All Items](https://mobbin.com/screens/d5304d9e-2e1d-4bbf-bdb0-40cdb34c6d2e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): app icon, title, email as second line, chevron; "All Categories" dropdown and sort icon above a search field; date group header; "3 Items" footer.
- [1Password, alphabetical grouping](https://mobbin.com/screens/c9cee426-d2fe-4b8b-acba-98be0a5eff73?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the same list under "#", "F", "J" section letters after sorting by title.
- [Apple Notes, list with a Pinned section](https://mobbin.com/screens/ff5bb02d-d35d-4eb6-80ce-e6668947104a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): collapsible "Pinned" header above "Previous 7 Days"; each row is title plus time and first line; search pill and compose button at the bottom.
- [Raycast Notes](https://mobbin.com/screens/f781653a-f6a8-47c0-bc7e-0cfe82c9b8b6?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): date-grouped single-title rows with "Edited 10 hours ago · 1,415 Characters" as metadata; bottom search pill and "+".
- [Cursor, All Agents](https://mobbin.com/screens/968ea1e2-797e-46cf-a30b-b6551cc0375e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Pinned" and "Recents" sections; a small status dot, title, a grey slug-like second line and a right-aligned age.

Row anatomy details worth borrowing:

- [Trust Wallet, Select Asset](https://mobbin.com/screens/552bc27b-7a6c-49d4-8e75-4717e1f56408?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): bold ticker followed by a small grey rounded label for the network on the same line, full name beneath. A good model for "short code + label" without a full chip.
- [Phantom, receive addresses](https://mobbin.com/screens/4d9778ed-2ba4-48d6-be47-e52696a05d14?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): name plus a tiny badge ("Taproot", "Native Segwit"), a truncated address beneath, and two trailing icon buttons (QR, copy) per row.
- [Obsidian, Keychain](https://mobbin.com/screens/8137c9be-ffdb-453a-80eb-7157bfaa0b0d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a secret row with name, "Never accessed" beneath, and trailing pencil and trash icons; the row itself never shows the value.
- [Matter, selection list](https://mobbin.com/screens/a7a67be8-ab72-4e0e-acf7-0312de48b41d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): favicon, title, a one-line source/age/read-time line, and a single coloured tag label on a third line only for the item that has a tag.
- [Pocket, Saves](https://mobbin.com/screens/d915dbe8-b7ff-4518-8cb8-786f657dccbc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): tag shown as a grey labelled chip under the title; trailing star, share and overflow on every row.
- [Quo, Snippets](https://mobbin.com/screens/364e320e-efbe-4f5d-8951-66f46c79a783?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [OpenPhone, Snippets](https://mobbin.com/screens/b5aa3ce2-36c4-4617-a4cd-9cd7f04f4c0e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the closest domain match. Name on line 1, the snippet text on line 2, a search field on top and a FAB bottom right. Nothing else.
- [Wispr Flow, Snippets](https://mobbin.com/screens/a2a0b362-68fb-446e-8321-aa2cdf5bf4f1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): each entry reads "trigger → expansion" as one paragraph under a "Your snippets (3)" count.

What does not work:

- Card lists. [Wispr Flow's Scratchpad](https://mobbin.com/screens/b949802c-86cd-41ce-957b-2205b44b32d3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) fits two notes on a screen; [Bear](https://mobbin.com/screens/6bd7f900-5d0f-47d6-a706-5c34495a8dff?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) spends most of each row on thumbnails. Fine for reading, wrong for lookup.
- Per-row action clusters. Pocket's three trailing icons on every row add noise and shrink the title. Two trailing actions (Phantom) is the practical ceiling, one is better.
- Rows that are navigation only. In [1Password](https://mobbin.com/screens/d5304d9e-2e1d-4bbf-bdb0-40cdb34c6d2e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) the list cannot copy anything; every copy costs a push, a field menu and a pop.

### 2.2 Search

What the best apps do: search is always visible, filters as you type in place, highlights the matched characters, shows a result count, and keeps scope controls on screen when nothing matches.

- [Wispr Flow, searching notes (flow)](https://mobbin.com/flows/926a33ab-cd03-4d27-a89a-515b52c9af8e?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a persistent field above the list; typing "Golden" narrows the same list in place; "No Results for "Mobbin" / Check the spelling or try a new search." replaces it when empty.
- [Apple Notes, searching (flow)](https://mobbin.com/flows/d50276d4-7219-40a3-b693-a4c442dea7a0?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): bottom search bar; results grouped as "Top Hits · 2 Found", "Notes", "Attachments"; matched letters are coloured yellow in both title and excerpt; a filter token ("Attachments") can sit inside the field.
- [Obsidian, search](https://mobbin.com/screens/3add8f95-d23d-42ec-92c2-0c23eb5c096b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "5 results", a sort control ("File name (A to Z)"), an "Aa" toggle, and yellow highlights on matches inside excerpts grouped under each file.
- [Obsidian, tag query](https://mobbin.com/screens/da212ff4-5852-49ae-968e-2dc23ece2c4a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the query `tag:#Pizzas` typed as text returns the one tagged line. Operators suit this audience.
- [Evernote, search results](https://mobbin.com/screens/2952cb28-ffd2-4c40-abcf-9342b1d7e7d0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "3 RESULTS", highlighted "Cost" in excerpts, tag label under each result, and dashed "+" filter chips above.
- [Slack, search](https://mobbin.com/screens/0f348274-59b2-431c-b6fc-9dd0040fd475?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "4 results found", "Newest" sort, dropdown filter chips, highlighted term, search field docked at the bottom.
- [Otter, search](https://mobbin.com/screens/0a13bb45-3a25-4bc1-a283-67a2d9756370?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "1 result" and three excerpts from the same item, each with the term highlighted and a trailing ellipsis.

Recent searches:

- [Weverse](https://mobbin.com/screens/bc469b5d-fa0c-4bea-a05f-c03f39909aae?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [Fabric](https://mobbin.com/screens/bc554754-d5e5-4056-a79c-bcf7500c9be1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a "Recent searches" header with "Delete all"/"Clear" and one row per query.
- [Meta AI](https://mobbin.com/screens/7f473a6f-b6a6-4273-b8c7-d021b847eb44?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): shows recent items ("Recent conversations") rather than recent queries, which is the more useful zero-query state for a personal library.

No results:

- [Evernote](https://mobbin.com/screens/4d1beb3e-8944-4ad5-9c62-bfdc2c3d3663?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "No notes found / Try using a different keyword or filter." with a "Create a note" button.
- [Bolt Food](https://mobbin.com/screens/e4ae78d1-c7c2-46f1-bd8e-ee72114e470e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): echoes the query, "No results found for Orangejuice".
- [Upwork](https://mobbin.com/screens/cb2f2e87-7e2e-44f1-952f-c9a70030f4cc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): names the scope, "No results found within Messages".
- [ClickUp](https://mobbin.com/screens/d37d1a5f-070e-41b8-8454-d43729ef2864?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the scope tabs and filter chips stay visible above the message, so the fix is one tap away.

What does not work:

- Search without a visible field. [Bear](https://mobbin.com/screens/2e6b36e9-8e8d-4b4f-a2f0-58aa320177d0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) offers a magnifier icon in the bar and a search button that appears above the first note when the list is pulled down. For a search-first tool that is one step too many.
- Mascot empty states ([Discord](https://mobbin.com/screens/4806bd8c-4eab-4f57-9610-7163f5627c2e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), "We searched far and wide…"). Wrong tone for this product.
- Recent-query lists with promo cards ([Deepstash](https://mobbin.com/screens/e3f4b43c-2df5-4ac0-b6b0-14a51d21fd6d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Queries against a local library are cheap to retype; the list is clutter.

### 2.3 Tag filtering

What the best apps do: selected tags are visually separate from available ones and removable in place; counts sit next to each option; the result count updates before the user commits.

- [Pocket, Tagged filter](https://mobbin.com/screens/d915dbe8-b7ff-4518-8cb8-786f657dccbc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): scope chips ("All", "Listen", "Tagged" and a starred one cut off at the edge), then the active tag as a removable chip ("interesting articles ×") directly above the filtered list.
- [Tinder, interest search](https://mobbin.com/screens/88b944a7-6522-4c0f-b637-59c6e35cdbcb?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): selected tags pinned above the field as dark chips with "×"; the same tags are filled inside the cloud below.
- [eBay, Filters](https://mobbin.com/screens/53a7dde4-d8f7-49d1-8652-5be4d7b5b321?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Filters / 302 results", a "Selected (1)" group with a removable chip, collapsible groups, "Clear all" and "Show results".
- [Insight Timer, Filter by](https://mobbin.com/screens/f532c0e9-58ed-44c0-9d6e-572b20aeba58?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [Wolt, Filter](https://mobbin.com/screens/b2362a3d-2aae-45f3-8b77-4aa0be982fc0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the commit button carries the live count ("Show 169 results", "Apply (177 found)").
- [Agoda, Sort and filter](https://mobbin.com/screens/6267a569-43ab-45ec-a112-e08c0aebda9c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a count beside every group heading ("Attractions (284)").
- [Craft (web), All Tags](https://mobbin.com/screens/74aad2dc-0748-4a97-a71a-d09d689f1e31?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a single row of tag chips, each with its count ("# holiday 2"), above the documents.
- [Obsidian, Tags view](https://mobbin.com/screens/db670cff-67d6-433c-aaf3-4bf89931a121?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a plain list of tags with right-aligned counts.
- [1Password, category dropdown](https://mobbin.com/screens/58bb4b9b-7dcd-428b-9779-7ccdd7a50c03?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the active filter turns the dropdown into a filled, coloured control so the filtered state is obvious.

What does not work:

- Tri-state chips. [Character AI](https://mobbin.com/screens/0a4e712a-56c8-444b-ba82-602ea6ccb79e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) says "Tap tags to filter your results. Tap again to exclude." A third state on a chip is not discoverable and not needed for AND filters.
- Cancel/Apply for filters that are instant and local ([Airwallex](https://mobbin.com/screens/c8a16042-c600-439b-9d23-91dda0ea985a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). It makes sense for a server round trip, not for an in-memory list.

### 2.4 Tap-to-copy feedback

What the best apps do: confirm at the place the user tapped, name what was copied, and keep the confirmation small and away from the next thing they need.

- [Phantom, address copied](https://mobbin.com/screens/4d9778ed-2ba4-48d6-be47-e52696a05d14?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the tapped row's copy icon turns into a check mark and a small "Address copied" pill appears at the top. The inline change says which row; the pill says what happened.
- [1Password, "Copied item link"](https://mobbin.com/screens/6fc1eaff-42e0-4863-a3b7-e8a31176adcf?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a quiet white toast above the tab bar, no icon.
- [1Password, field menu](https://mobbin.com/screens/f93aeb4d-8801-43e2-8613-32e160d3fc6e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the per-field menu is "Copy", "Reveal", "Show in Large Type", "Pin to Home". Copy is first and does not require revealing.
- [Linear, code block](https://mobbin.com/screens/11ab9beb-3913-4183-9e46-fc456edb7660?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): copy icon in the block's corner; "Code contents copied to clipboard" appears directly under the block.
- [Xbox](https://mobbin.com/screens/976c8003-40cb-41ae-868e-1428e51a284a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [GoodRx](https://mobbin.com/screens/3bf79f6e-55e6-4a64-8172-9f4e2b26354c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): bottom snackbar with a check, sitting above the tab bar or home indicator.
- [Matter, API token](https://mobbin.com/screens/a0313ada-4442-4160-9a9e-5d448f935fe0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): monospace token on one line with a copy icon at the end, and "Hide Token" as a separate row.

What does not work:

- Blocking confirmations. [mymind](https://mobbin.com/screens/1010dd77-4098-42a1-bd6c-cb530d2da459?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) dims the screen for a centred "Copied to Clipboard" card; [Kraken](https://mobbin.com/screens/0023d9b8-22d5-44a8-88e4-b92cfbdafb3b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) blurs everything and repeats the whole address.
- Feedback that covers the thing copied or the next action. [Formula 1](https://mobbin.com/screens/020891c5-f8d3-46c9-bf67-bc008d465148?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) lays the pill over the field; [Finch](https://mobbin.com/screens/92e0e7df-346a-4827-bfd9-5be1ab7bf398?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) puts the toast hard against the "Continue" button it is asking the user to press next.
- Long sentences ([Forest](https://mobbin.com/screens/ae813cc2-43e0-4dcb-b26f-d4fc6f681c70?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Your personal code has been copied to your clipboard."). Two words are enough.

### 2.5 Swipe, context menus, multi-select, pinning, undo

Swipe:

- [The Atlantic, Saved](https://mobbin.com/screens/e97a2ae1-ef94-4f8d-bdfb-f85b325a9936?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): full-height red "Delete" on a left swipe, and a kebab on each row for everything else.
- [Vestiaire Collective](https://mobbin.com/screens/0216d045-24b0-4d59-a9ab-9657d885e76f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): two labelled swipe actions, "Move to Favorites" and "Delete".
- [Notion Mail, Swipe Settings](https://mobbin.com/screens/991c9208-8165-4f58-b43d-735cdd52865a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the user assigns actions to right and left swipes, with a preview. A power-user option, not a default.

Menus:

- [Apple Notes, note menu](https://mobbin.com/screens/8cb63dab-d783-437a-9e51-5046311e3712?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a row of three icon actions on top ("Scan", "Pin Note", "Lock"), then a short list, with "Delete" in red last.
- [Raycast, note menu](https://mobbin.com/screens/053ae09f-bc0e-456b-98a7-84947be58d65?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): six items: "Add to Favorites", "Export As", "Copy Deeplink", "Find in Note", "Duplicate", red "Delete Note".
- [DeepSeek, row menu](https://mobbin.com/screens/e66a5318-a324-4617-94a7-dcffd780e50a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): two items, "Copy link" and red "Delete". Short menus read instantly.
- [Bear, tag menu](https://mobbin.com/screens/14e69637-1d44-4e08-af29-a0b38fd715e1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): long-press on a tag gives "Edit tag", "Export…", "Toggle Pin", "Delete".

Multi-select:

- [Matter](https://mobbin.com/screens/a7a67be8-ab72-4e0e-acf7-0312de48b41d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the title becomes "1 selected", leading circles become checkboxes, and four icon actions (tag, read, archive, red trash) float at the bottom.
- [Todoist](https://mobbin.com/screens/91160ad8-4c10-4abe-8ee0-d2909ec85b5f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "2 selected", "Select All", and a menu whose labels carry the count ("Delete 2 Tasks", "Duplicate 2 Tasks").
- [Apple Wallet](https://mobbin.com/screens/43e18b61-d92d-41fd-b3f8-262941692aa3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Select All · 2 Selected · Cancel" on top, trash and hide at the bottom corners.
- [Apple Notes, bulk tagging (flow)](https://mobbin.com/flows/ae9c6a3e-81a8-4218-af75-ef331bed9a86?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Select Notes" in the list menu, then a Tags sheet: "Select tags to add to the selected notes. Deselect existing tags to remove them."

Pinning:

- [Apple Notes, pinning (flow)](https://mobbin.com/flows/7c1527a6-fd39-4c15-b383-887a1f53392e?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Pin Note" in the menu; the list gains a "Pinned" section.
- [Perplexity, pinning (flow)](https://mobbin.com/flows/3858f0b4-f9e8-48a9-a2cf-f4e3eca35367?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Pin / Dismiss / Delete" in a row menu; a small pin icon then appears at the row's trailing edge.
- [1Password, favourite](https://mobbin.com/screens/3fbf73a2-e0a6-404b-b9a9-b91fd742f549?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a star badge on the item's icon.

Undo after delete:

- [1Password, Deleted "Figma"](https://mobbin.com/screens/e28306d2-8e5e-4ea4-94a5-bd0e1c3d5d5d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): names the item and offers "View" and "Undo".
- [Meta AI, Reminder deleted](https://mobbin.com/screens/30cf4541-187a-4638-86c0-22e435a51e4d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): two-line snackbar, the second line repeats the deleted item's text, "Undo" at the right.
- [Google Photos](https://mobbin.com/screens/271108af-b336-489e-bac3-7b4639152cb4?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) (after an unstack action) and [Spotify](https://mobbin.com/screens/a2495459-509e-47ce-a925-e93e063d856c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) ("Notification deleted."): one-line snackbar with a text "Undo", placed above the bottom bar.
- [1Password (web), Archived](https://mobbin.com/screens/7d09b178-6584-47bb-98c5-11e5b7397862?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the same pattern on a wide layout, centred at the bottom of the detail pane.

What does not work:

- [Evernote's note sheet](https://mobbin.com/screens/e02408ee-1a3a-4218-9dcc-c26f09254741?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): fourteen or more actions in one scrolling sheet, including a disabled one.
- [Speechify](https://mobbin.com/screens/ce3ed5be-50c9-4b07-ba66-aa81a1ec1f03?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "These files has been permanently removed" next to an "Undo" button. The message and the action contradict each other.
- [Udemy, deleting a note (flow)](https://mobbin.com/flows/96100ccd-1eba-4743-87f7-bc3a8bbeaaa4?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a "Please confirm" alert, then a "Note deleted" banner with no undo. Two interruptions and no recovery.
- [Quo](https://mobbin.com/screens/28233f22-360a-456d-9973-ef2942fdf2fa?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the snackbar overlaps the floating tab bar.
- [Apple Notes, deleting (flow)](https://mobbin.com/flows/1987c666-66ec-4101-b98f-f6c9500d9b99?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Delete" in the menu, then the list without the note. No confirmation and no undo are visible in the flow; the app relies on a recently-deleted folder that the flow does not show.

### 2.6 Creating

- FAB at the bottom right: [Bear](https://mobbin.com/screens/6bd7f900-5d0f-47d6-a706-5c34495a8dff?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Quo](https://mobbin.com/screens/364e320e-efbe-4f5d-8951-66f46c79a783?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [OpenPhone](https://mobbin.com/screens/b5aa3ce2-36c4-4617-a4cd-9cd7f04f4c0e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp). A labelled variant: [Claude, "+ New project"](https://mobbin.com/screens/95d84616-c65e-4722-9042-46764480514f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) above a bottom search field.
- Toolbar "+": [1Password](https://mobbin.com/screens/d5304d9e-2e1d-4bbf-bdb0-40cdb34c6d2e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) uses a filled blue circle at the top right on every list screen.
- Short form, one screen: [Opera, adding a password (flow)](https://mobbin.com/flows/c40fc023-644a-4857-8411-8cd697c8155f?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): three fields, "Save", "Cancel", and the new row is simply there afterwards. [Muse (flow)](https://mobbin.com/flows/8931d14f-a722-424c-bd51-13f1b38c268e?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) ends with a small "Login details added." toast.
- Two-field sheet: [ChatGPT, Add text](https://mobbin.com/screens/3b0c22cc-8b7a-41ce-91eb-4ae078416684?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Title (optional)" and "Text", with "Cancel" and "Save" in the bar. [Tripadvisor](https://mobbin.com/screens/d7bb38c0-f257-4736-93f9-37cacae55d40?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) adds a "42/1000" counter.
- Paste affordances: [Otter, "Paste URL from clipboard"](https://mobbin.com/screens/8188ee4c-9d4d-49f9-8df8-8cdb6946fe71?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) as a text link under the field; [Aave](https://mobbin.com/screens/c7dae200-373f-4789-b1c0-615f1a1df0aa?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [Blinkist](https://mobbin.com/screens/bbf58a53-b45d-4853-b9f8-28488d6150fb?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) put a "Paste" button inside the field; [Craft](https://mobbin.com/screens/4d42ae11-40b4-4848-862e-a378669fd751?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) uses a clipboard icon button.

What does not work:

- Reading the clipboard without being asked. [MacroFactor](https://mobbin.com/screens/add6e4ed-369b-40a7-9334-2dd805da72dc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) shows the system banner "MacroFactor pasted from Safari" above a link field that is already filled in. For an app that stores secrets, that banner on every launch looks like a leak.
- Title-only quick add ([ClickUp, New Note](https://mobbin.com/screens/ab2bd76b-db83-40c9-84e3-669008bbe72c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)): the sheet has no place for the content, which is the part that matters.

### 2.7 Editor and detail

Read and edit as separate modes (1Password):

- [1Password, item detail](https://mobbin.com/screens/517cf2c2-aad6-4007-a66a-c543c84d591e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): small coloured field labels above values, a "…" per field, masked password with a strength meter, tags at the bottom, and "Edit" in the bar.
- [1Password, revealed password](https://mobbin.com/screens/e9a15a95-7c25-49ae-9224-ad818e4810d8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the value is shown in place, in the same row.
- [1Password, Editing](https://mobbin.com/screens/3a362fc5-7081-469b-bee9-d9f8b01223aa?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Cancel · Editing · Save", grouped field cards, red minus to remove, drag handles, "+ add more".
- [1Password, new item](https://mobbin.com/screens/0c5f33dc-a81d-4f76-a70e-c8e3bf58dbe1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a "Create a New Password" accessory sits above the keyboard when the password field has focus.

Single-screen editors:

- [SoundCloud, Edit](https://mobbin.com/screens/ef68975d-8e3f-4552-9fdc-5efd4bf6075f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): label-above-value rows, a character counter, and a "Private" switch as the last row.
- [GitHub, Edit fields](https://mobbin.com/screens/ca782bc2-2308-41c8-80b5-17bf3c57f927?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): icon, label and value per row; "Edit" where the value is empty.
- [Alta, item detail](https://mobbin.com/screens/d96597bf-ebc4-4423-9ad4-b51044f20850?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): each metadata row holds its chips ("Tags: casual, workout") or a placeholder ("Add seasons").

Tag input:

- [Upwork, skills](https://mobbin.com/screens/1cc8688d-650f-478d-a57e-42439cce2c24?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): chips with "×" inside the text field itself, the caret after the last chip, "Max 15 skills", and suggestions as "+" chips underneath.
- [Oura, Add a tag](https://mobbin.com/screens/a0605b7f-83c0-40fd-962b-e4641cdd50dd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): typing "Late" lists "Matching tags", and the first option is "+ Create a tag".
- [Pinterest, Tag topics](https://mobbin.com/screens/337709a5-ee84-40a9-820d-f92c1c2d4d9a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a "Selected" group separate from suggestions.
- [Obsidian, inline tag (flow)](https://mobbin.com/flows/65db7d10-61a7-48ba-9242-1e3e45a86063?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): typing `#Day` in the body turns it into a tinted token.

Monospace and code:

- [Craft, Edit Code](https://mobbin.com/screens/611f805b-52e9-4dc8-90f1-a15a307a8367?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): dark panel, line numbers, "Copy" at the bottom left.
- [Perplexity, script viewer](https://mobbin.com/screens/f27aed36-a394-4c1e-a167-431ba28d9614?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): file name in the bar, copy and share icons top right, a language label above the text.
- [Linear, code block](https://mobbin.com/screens/11ab9beb-3913-4183-9e46-fc456edb7660?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): compact monospace block inside a normal document, copy icon in the corner.

Secrets:

- [Apple Photos, Hidden](https://mobbin.com/screens/01f45e7a-2178-4ecf-9f80-8a8fc6a56bbf?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a lock icon, "Use Face ID or Enter Your Passcode to View This Album", and a "View Album" link. The locked state explains itself and offers the action.
- [CLEAR, vault card](https://mobbin.com/screens/3c9f89d5-8e16-4f77-8cdd-1fe3f9f07907?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the card is blurred behind a "Show Details" button with an eye icon.
- [CLEAR, revealed fields](https://mobbin.com/screens/23654b52-7494-4251-a97b-81ecb5662bb6?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): each field keeps its own copy icon.
- [ChatGPT, key ready](https://mobbin.com/screens/88a91617-6374-4411-b39c-a26931663b76?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "You will not be able to retrieve this key again." beside "Copy key". Plain consequence text next to the action.

Discard confirmation:

- [Notion Mail](https://mobbin.com/screens/609a0ba1-36d1-4326-8735-a548bb4da0c2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a small popover at the close button, "Are you sure? You have unsent changes." with "Save Draft" and red "Discard".
- [Givingli](https://mobbin.com/screens/f3e0489d-a8d3-4459-9e67-9f5c3a30df1d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): an action sheet, "Save Draft / Discard / Cancel".

What does not work:

- [GoPro Quik](https://mobbin.com/screens/beed654c-76cd-4e1d-b533-038a3c4667d3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the destructive button is labelled "Cancel changes" next to "Back to edit". "Cancel" in a discard dialog is always ambiguous.
- [5 Minute Journal](https://mobbin.com/screens/63d002c8-1ba7-48ac-8b03-8e52c32948fc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the text says the answers are saved while the buttons are "Close entry" and "Discard".
- [Gojek](https://mobbin.com/screens/302f5179-3aca-4211-8218-d89f081ce3eb?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a half-screen illustration to ask "Save this as a draft?".
- Code that wraps mid-token ([Gemini](https://mobbin.com/screens/084aad68-f95f-49bb-914c-3889671090ad?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) or scrolls sideways with clipped lines ([Cursor](https://mobbin.com/screens/ca182c85-0169-45a6-a3e3-a01f1bb01d54?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
- No reference showed an autosave indicator. The only "saved" signals found are list metadata ([Raycast](https://mobbin.com/screens/f781653a-f6a8-47c0-bc7e-0cfe82c9b8b6?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), "Edited 10 hours ago") and the character count pill in [Raycast's note view](https://mobbin.com/screens/053ae09f-bc0e-456b-98a7-84947be58d65?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).

### 2.8 Empty states and first run without an account

- [ChatGPT, Projects](https://mobbin.com/screens/0e3ce245-62be-49b4-93aa-54108b9fcd85?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a small icon, "Start your first project", one sentence, one button; the search field is already there.
- [Claude, Projects](https://mobbin.com/screens/95d84616-c65e-4722-9042-46764480514f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "No projects yet" and one sentence; the create action is the labelled FAB, so nothing is duplicated.
- [Bluesky](https://mobbin.com/screens/05bf0bb9-ab40-4a9b-934d-30f65a96f66a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): one line and a "Create +" button. The minimum that works.
- [Wispr Flow, Snippets](https://mobbin.com/screens/a2a0b362-68fb-446e-8321-aa2cdf5bf4f1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a dismissible card, "The stuff you shouldn't have to re-type", with examples ("emails, links, addresses, bios") and "Add new snippet". It teaches what a snippet is, which a bare empty state does not.
- [[untitled]](https://mobbin.com/screens/a871be3f-acf8-4265-9462-b4ddf5fea9dd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a tertiary "Learn how to import" link under the main action.
- [Obsidian, sync prompt](https://mobbin.com/screens/c464d280-72a1-4984-b7b9-02bed72b99db?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "You can set up sync now, or just start writing and set it up later." with "Continue without sync" as the primary button and "Set up sync" as the secondary. Local-first stated plainly.

What does not work: account-first welcome screens such as [Arc Search](https://mobbin.com/screens/90a48d5a-ac1c-49ff-b8d7-34898122ee42?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) ("Sign in with Arc" / "I don't have an account") or [Brink](https://mobbin.com/screens/6e802e77-760d-4806-bdbe-05bf0a9a4639?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) ("Sign in with Apple" / "Continue as Guest"). They frame local use as the lesser option.

### 2.9 Large-screen list-detail

- [1Password (web)](https://mobbin.com/screens/3d59932f-7866-4241-a5aa-577e393e1088?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): three panes. Sidebar with "All Items", "Favorites", categories and a list of tags; a narrow item list with category dropdown, sort and section letters; a detail pane with "Share", "Edit", fields, tag chips and "Last edited".
- [1Password (web), nothing selected](https://mobbin.com/screens/7d09b178-6584-47bb-98c5-11e5b7397862?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the detail pane shows only a faint illustration while the list stays usable.
- [Proton Pass (web)](https://mobbin.com/screens/54c3c431-e6e5-459f-9d1b-9e37c382fb8b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): vaults with counts in the sidebar, "Search in all vaults…", filter chips "All (3)" and "Recent", a "Multiple select" button and a date-grouped list; in this frame a password-history panel covers the detail column.
- [Evernote (web)](https://mobbin.com/screens/ddac6d88-fa48-41f4-bd1f-4611629e3879?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): sidebar, a card list with title, preview, date and tag labels, and the editor with an "Add tag" footer.
- [Obvious (web)](https://mobbin.com/screens/bc69ec4e-5c67-455d-9d29-d62b5d38c34a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): sidebar, "Notes · 2" list with its own search field, editor with a timestamp at the top and a floating format bar.
- [NordPass (web, listed under NordVPN)](https://mobbin.com/screens/f0e75746-817f-43cb-bb74-28d540fc31bd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [Lightfield (web)](https://mobbin.com/screens/e7e29b92-a39d-4eb4-8d31-ac3ee2c01849?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the detail appears as a right-hand panel over the list instead of a pane beside it; in NordPass it covers the list's "Last used" column.

What does not work: slide-over detail panels on a wide screen. They hide part of the list the user is navigating, and they have no stable position. Grid cards for credentials ([Cloaked](https://mobbin.com/screens/4aeb95f0-1b60-4f39-9006-f1541ce7d8b8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) show four items where a list shows twenty.

---

## 3. Recommendations for Snippets Android

### 3.1 Library screen structure (phone)

```
┌────────────────────────────────────────────┐
│ status bar (transparent, edge-to-edge)     │
│ ┌────────────────────────────────────────┐ │
│ │ [search] Search snippets         [more]│ │  SearchBar, always visible, never expands
│ └────────────────────────────────────────┘ │
│ [filter] (work 12) (links 7) (personal 5) →│  LazyRow of FilterChip, one line
│ Pinned                                     │  sticky header, titleSmall
│  row                                       │
│  row                                       │
│ All snippets                    Edited ▾   │  sticky header + sort TextButton
│  row                                       │
│  row                                 (+)   │  FloatingActionButton
│  … 42 snippets                             │  footer count, bodySmall
│ nav bar inset (content scrolls underneath) │
└────────────────────────────────────────────┘
```

- One destination, no bottom navigation, no navigation drawer. Settings and sync status live in the search bar's trailing overflow (`IconButton` + `DropdownMenu`).
- Do not copy the iPhone's bottom bar (filter, search, "+"). On Android the bottom edge belongs to the gesture bar and the IME; a top `SearchBar` plus a FAB is what users of Keep, Files and Gmail already know.
- `LazyColumn` with `stickyHeader` for "Pinned" and the main section. Section headers replace per-row pin badges in the default view (Apple Notes, Cursor).
- Sort lives on the main section header: Recently edited (default), Name, Recently used if usage data exists on Android. Model: [1Password's sort menu](https://mobbin.com/screens/071c9ec2-33e3-4f84-a001-7187b1a297eb?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
- End the list with a quiet count ("42 snippets"), as 1Password does.

### 3.2 Row anatomy

```
Ordinary entry, with tags (84 dp)
┌──────────────────────────────────────────────────┐
│ Meeting room                         [pin] [edit]│  1: name · state icons · open-editor button
│ \meet  https://meet.example.com/design-rev…      │  2: keyword (mono) + body preview
│ work   links                                     │  3: tags, only when the entry has any
└──────────────────────────────────────────────────┘

Secure entry (68 dp, no tags)
┌──────────────────────────────────────────────────┐
│ Staging API token                   [lock] [edit]│
│ \stg   Encrypted · authenticate to copy          │
└──────────────────────────────────────────────────┘

Keyword disabled: only the keyword token changes
│ \reply*  Thanks for reaching out. I will take…   │  * struck through, outline colour

Just copied: line 2 for about 1.5 s, then back
│ [check] Copied                                   │
```

- Tap the row: copy (the product's main job; parity with iPhone). The trailing `IconButton` (48 dp target, 20 dp `Icons.Outlined.Edit`, `onSurfaceVariant`) opens the editor. Evidence for a row whose tap and trailing button do different things: Phantom, Obsidian Keychain.
- Line 1, name: `titleMedium` (16/24, medium), one line, ellipsis. No timestamp. The iPhone row spends its top-right corner on an edit time that does not help anyone find or copy anything; that slot holds state icons instead.
- Line 2: keyword then body preview. Keyword in the monospace family at `labelLarge` size on a `surfaceContainerHigh` rounded rectangle (4 dp radius, 6 dp horizontal padding), not a Material chip: chips look tappable. The preview is `bodyMedium`, `onSurfaceVariant`, one line, first non-empty line of the body with whitespace collapsed. Model: Trust Wallet's ticker plus label.
- Line 3: tags as plain labels, `labelSmall`, 20 dp high, tonal container, at most one line, then "+2". Text always present. Do not port the iPad's colour-only tag dots: colour without text fails for colour-blind users and means nothing until the palette is memorised.
- Tag colour: keep a deterministic hue per tag for continuity with the Apple apps, but generate it through tonal palettes (container tone about 90 in light, 30 in dark) so contrast holds under dynamic colour.
- Pinned: the "Pinned" section is the indicator. In search results and tag-filtered views, where sections collapse into one ranked list, show a 16 dp `PushPin` icon before the edit button (Perplexity).
- Secure: 16 dp `Lock` icon in the state slot and the fixed preview "Encrypted · authenticate to copy". No bullet mask: dots imply a length and suggest tap-to-reveal in the list.
- Disabled keyword: only the keyword token changes (strikethrough, `outline` colour). Do not dim the row, because the entry still copies normally. Drop the iPad's green "enabled" dot: marking the normal state on every row is noise; mark the exception.
- No leading icon or avatar. Snippets have no visual identity, and a column of identical glyphs costs 56 dp of width on every row.

Density and type:

| Element | Role | Size |
|---|---|---|
| Row name | `titleMedium` | 16/24 sp, weight 500 |
| Body preview | `bodyMedium`, `onSurfaceVariant` | 14/20 sp |
| Keyword | monospace, `labelLarge` metrics | 14/20 sp |
| Tag label | `labelSmall` | 11/16 sp, 20 dp container |
| Section header | `titleSmall`, `onSurfaceVariant` | 14/20 sp |
| Editor body | monospace | 14/20 sp (follows font scale) |

- Row padding 16 dp horizontal, 10 dp vertical; 68 dp without tags, 84 dp with. About 7.5 three-line rows or 9.5 two-line rows on a 6.1-inch phone below the search and chip rows.
- Inset `HorizontalDivider` in `outlineVariant` between rows. Material lists often omit dividers, but with three lines of mixed type they keep entries apart at a glance.
- A "Compact list" setting (two lines, tags hidden) is worth having for libraries of several hundred entries. Default stays three-line because tags are how this library is organised.
- Rows must survive 200 % font scale: lines 1 and 2 stay single-line, the row grows in height.

### 3.3 Search

- Material 3 `SearchBar` pinned at the top and used as an in-place filter: keep `expanded` false and filter the `LazyColumn` underneath. Do not open the full-screen search view; the list is the result set (Wispr Flow, 1Password "Find in All Items"). On tablets use `DockedSearchBar` at the top of the list pane.
- The bar stays put while scrolling. Do not use an enter-always collapse: a lookup tool should never hide its lookup.
- No keyboard on cold start. Pinned entries must be tappable immediately; the IME would cover half of them. Offer "Focus search on open" as a setting and as a launcher shortcut.
- Search as you type, no submit step. The IME action is "Search" and only hides the keyboard.
- Highlight matched characters in name, keyword and tags (fuzzy subsequence, like Apple Notes and Obsidian) and the matched run in the body. When the hit is in the body, line 2 becomes an excerpt centred on the match with leading "…" (Otter, Obsidian). Use a `tertiaryContainer` background span with `onTertiaryContainer` text, not literal yellow, so it holds in dark theme.
- Show the result count in the section header ("12 results"), and collapse "Pinned" and "All snippets" into one ranked list; pinned entries get the row-level pin icon.
- Support `tag:name` as typed text and convert it to a selected filter chip (Obsidian's operator, Apple Notes' token). Cheap, and right for this audience.
- No recent-search list. Zero-query state is the library itself with pinned entries on top.
- No results: "No snippets match "query"" plus, when tag filters are active, "in work + links" and a "Clear filters" `TextButton`; then a `FilledTonalButton` "New snippet named "query"". One line of `bodySmall` underneath: "Secure snippet bodies are not searched." Models: Evernote (create from no results), Bolt Food (echo the query), Upwork (name the scope), ClickUp (keep filters visible).
- Back: with a query or focus, the first back clears the query and focus; the second leaves.

### 3.4 Tag filter

- One horizontally scrolling `LazyRow` of `FilterChip` under the search bar, each with its count as trailing text ("work 12"). Selected chips move to the front and show the check icon. Do not wrap to several lines on a phone as the iPad sidebar does; that costs two or three rows of list.
- AND semantics, as on the Apple apps. Counts are faceted: with "work" selected, every other chip shows how many entries have both. Chips whose count is zero drop to the end, disabled.
- The first item in the row is an `IconButton` (`FilterList`) with a badge showing the number of active tags. It opens a `ModalBottomSheet`: a text field to filter tags when there are more than about 20, a `FlowRow` of the same `FilterChip`s with counts, a sort toggle (count / A–Z), and "Clear all". Changes apply live; the sheet's handle and the scrim dismiss it. No Apply button (the eBay/Wolt count-in-button idea becomes the live section header instead).
- When any tag is active, the main section header reads "work + links · 4 snippets" with a trailing "Clear". The filtered state must be obvious without scrolling the chip row (1Password's filled dropdown, Pocket's removable chip).
- Long-press on a chip in the sheet: rename and delete tag (Bear). Not in the row above the list, where a long-press would be an accident.
- Hide the chip row entirely while the library has no tags.

### 3.5 Copy feedback

- In the row: line 2 cross-fades to a check icon and "Copied" for about 1.5 s, and the row container flashes `secondaryContainer`. This is the confirmation that says which entry was copied (Phantom).
- Haptic: `HapticFeedbackType.Confirm` on success and `Reject` on a failed or cancelled authentication, through `LocalHapticFeedback`, with a fallback to `ContextClick` on API 28–29. One short tick; no custom waveforms. View-based haptics already follow the system setting.
- System confirmation: Android 13 and later shows its own clipboard overlay after a copy, and platform guidance is not to add a toast or snackbar on top of it. So: API 33+, no generic "Copied" snackbar; API 28–32, a short `Snackbar` "Copied "Meeting room"". This is the main place where the iOS pattern (always show a toast) must not be copied.
- Secure copy is the exception: after `BiometricPrompt` succeeds and the clip is set with the sensitive flag (so the system overlay and keyboard suggestions mask it), show a `Snackbar` "Copied · clears in 60 s" with the action "Clear now". That snackbar carries information and an action, not just a confirmation.
- Entries with placeholders: the row confirmation reads "Copied with today's values" so the user knows the date or time was resolved at copy time.
- Never a dialog, never a full-screen overlay, never anything over the search bar.
- `Snackbar`s are hosted in the `Scaffold` so they sit above the FAB and inside the navigation bar inset (the Quo collision is the thing to avoid).

### 3.6 Gestures and selection

- Tap: copy. Trailing edit button: open. Long-press: enter selection mode with that row selected. This is the Android convention (Gmail, Files, Keep). Do not port the iOS long-press context menu with preview.
- Selection mode: the search bar is replaced by a contextual `TopAppBar`: close icon, "3 selected", then Pin, Tags, Delete and an overflow with Select all, Duplicate, Share, Enable or disable keyword. Rows show a leading `Checkbox`-style indicator; tap toggles. Secure entries can be selected, but Duplicate and Share are disabled with a one-line reason when the selection contains one. Models: Matter, Todoist (count in the title), Apple Notes (bulk tag sheet).
- Bulk tagging reuses the tag sheet with tri-state boxes (all, some, none of the selection).
- Swipe, with `SwipeToDismissBox`: start-to-end pins or unpins and springs back; end-to-start deletes. One action per direction, icon and colour revealed behind the row, committed at the threshold. Do not build iOS-style multi-button reveal rows (Vestiaire, The Atlantic).
- Swipes must start inside the content, not at the screen edge: with gesture navigation both edges belong to predictive back. Keep the default 16 dp content inset and never register system gesture exclusion rects for list rows.
- Add a "Swipe actions" switch in settings, on by default. Some users will prefer a list that cannot be changed by a stray swipe (Notion Mail's swipe settings are the richer version of this).
- Delete of an ordinary entry: immediate, then `Snackbar` "Deleted "Meeting room"" with "Undo", `SnackbarDuration.Long`. Bulk: "3 snippets deleted · Undo". Name the item (1Password, Meta AI).
- Delete of a secure entry: `AlertDialog` first ("Delete "Staging API token"? Its encrypted content is removed from this device and from sync."), buttons "Cancel" and "Delete". No undo snackbar, in line with the iPhone app offering inline undo for ordinary entries only.
- Back order with predictive back: selection mode, then search query and focus, then the detail pane (large screens), then the app. Register a back handler only while the corresponding state is active so the system's back-to-home preview still plays from the idle library.

### 3.7 Creating

- `ExtendedFloatingActionButton` "New snippet" while the list is at the top, collapsing to a regular `FloatingActionButton` (`primaryContainer`) on scroll. Bottom end, above the navigation bar inset. Hidden in selection mode and while the IME is open.
- It opens the full-screen editor directly, focus in the body. No quick-add bottom sheet: with the IME up, a sheet leaves three lines for the body, and the entry has five properties.
- Create from clipboard: never read the clipboard on launch. Android 12+ shows a system toast whenever an app reads it, which for a secrets app looks like a leak (the MacroFactor banner). Instead check `hasPrimaryClip()` and the clip description only, and when it holds text show a small `AssistChip` "New from clipboard" above the FAB on the empty state and inside the new editor ("Paste clipboard" in the empty body, like Otter's link). Read the content only on tap.
- Android-native capture the Apple apps do not have: a share target (`ACTION_SEND`, text) that opens the new-snippet editor with the shared text as body, the existing "Insert Snippet" text action, and launcher shortcuts "New snippet" and "Search".
- After saving a new entry, return to the list scrolled to it with the same row flash used for copy. No "Created" toast.

### 3.8 Editor, phone

```
┌────────────────────────────────────────────┐
│ [←]  Meeting notes        [copy] [pin] [⋮] │  TopAppBar; ← is Up, not Close
├────────────────────────────────────────────┤
│ Name                                       │  OutlinedTextField, single line
│ ┌────────────────────────────────────────┐ │
│ │ Meeting notes — {date:yyyy-MM-dd}      │ │  body: monospace, tonal container,
│ │                                        │ │  min 6 lines, grows, soft wrap
│ │ Agenda                                 │ │
│ └────────────────────────────────────────┘ │
│ Preview ▾                                  │  only if the body has placeholders
│ Keyword   \ notes                          │  OutlinedTextField, prefix "\", monospace
│           Suggested: \meeting              │  SuggestionChip / supporting text
│ Tags      (work ×) (notes ×) add tag…      │  InputChip tokens + inline field
│ Secure                             [switch]│  ListItem + Switch + supporting text
│ Keyword enabled                    [switch]│
│ Saved 21:04                                │  bodySmall, onSurfaceVariant
└────────────────────────────────────────────┘
```

- One scrolling screen. Drop the iPhone's bottom "Content / Details" segmented control: it hides keyword and tags behind a mode switch, and its position collides with the IME and gesture bar. Body first after the name, metadata below, as on the iPad.
- Top bar: `Icons.AutoMirrored.Filled.ArrowBack` as Up. Actions: Copy (the same behaviour and feedback as the list), Pin toggle, overflow with Duplicate, Share, Revert changes, Delete.
- Always editable; no separate read mode for ordinary entries. 1Password's read/edit split pays off for multi-field items with per-field copy; a snippet has one body and one copy action.
- Body: monospace 14/20, `surfaceContainer` background, 12 dp radius, soft wrap on, no line numbers, no syntax colouring except placeholders (`{date:…}`) tinted `primary`. Autocorrect and auto-capitalisation off for the body and keyword (`KeyboardOptions`), on for the name.
- Placeholder preview: a collapsible "Preview" block directly under the body showing the resolved text, visible only when the body contains a placeholder (the current iPhone design; Mobbin had no equivalent).
- Keyword: the trigger prefix is shown through the text field's `prefix` slot so it cannot be deleted or duplicated. Conflicts and duplicates appear as supporting text in `error` colour while typing; a suggestion derived from the name appears as a `SuggestionChip` when empty.
- Tags: tokens inside the field (`InputChip` with a trailing remove icon in a `FlowRow`, then the text input), Upwork's model. While typing, a row of `SuggestionChip`s sits above the IME with matching existing tags and their counts; the first is "Create "x"" when there is no exact match (Oura). Comma, Enter and space-after-text commit a tag; backspace on an empty input selects, then removes, the last token.
- Switches, not the iPad's checkbox: "Secure" with supporting text "Body is encrypted. Unlock is required to view, edit or copy." and "Keyword enabled". Turning Secure on asks for authentication at that moment; turning it off shows an `AlertDialog` stating that the body becomes ordinary, searchable text.
- Saving: autosave with a short debounce and on every lifecycle stop, with "Saved 21:04" at the bottom (the iPhone shows the same line). Back is therefore never intercepted, and predictive back animates normally. A new entry left completely empty is dropped silently. "Revert changes" in the overflow restores the state from when the editor opened and is offered again in a `Snackbar` after leaving ("Changes saved · Revert") for one session. No discard dialog exists in this design, which removes the whole class of wording problems seen in section 2.7.
- Secure entry, locked: name, keyword and tags are visible and editable; the body area is a tonal panel with a lock icon, "Encrypted. Unlock to view or edit.", and a `FilledTonalButton` "Unlock" that runs `BiometricPrompt` (Apple Photos' Hidden album is the model). Unlocked: the window sets `FLAG_SECURE` (no screenshots, blank in Recents), the body field is excluded from autofill and from IME learning, and a small "Lock now" text button replaces the "Saved" line's trailing space. The vault's own timeouts relock it.
- IME: `imePadding()` on the scroll container; keep the focused field and the tag suggestion row above the keyboard.

### 3.9 Tablet and foldable: list-detail

- `NavigableListDetailPaneScaffold` from the Material 3 adaptive library, with predictive back between panes. Compact width: single pane, as above. Medium (600–839 dp) and expanded (840 dp and up): list pane fixed at about 360–400 dp, the editor as the detail pane. No third pane and no navigation rail: there is one destination. Tags stay as chips above the list, and on these widths they may wrap to two lines as the iPad does.
- Two panes side by side, never a slide-over (the NordPass and Lightfield problem).
- Tap behaviour changes with the layout, and has to: in two-pane mode a row tap selects the entry and shows it in the detail pane (parity with iPad: "select and copy"). Copy is the detail top bar's first action and a trailing copy `IconButton` on the row, which replaces the phone's edit button. The copied row confirmation is the same.
- Selected row: `secondaryContainer` fill with 12 dp radius inside the list pane.
- Nothing selected: the detail pane shows a muted glyph, "Select a snippet", and the hardware keyboard shortcuts (1Password web keeps this pane almost empty; that restraint is right).
- Hardware keyboard: Ctrl+F focuses search, Ctrl+N new, arrows move the selection, Enter opens, Ctrl+C with list focus copies the selected entry, Delete deletes with the same undo. Publish them through the system keyboard shortcuts helper.
- The list pane keeps its own `DockedSearchBar`; the detail pane keeps its own top bar. On a fold or rotation the selected entry and scroll positions persist.

### 3.10 Empty states and first run

- First run goes straight to the empty library. No carousel, no account screen, no permission request.
- Empty library: centred column: a 40 dp outline glyph, `titleMedium` "No snippets yet", `bodyMedium` "Save a link, an address, a reply or a token once and copy it with one tap.", a `Button` "New snippet", and two `TextButton`s underneath: "Import…" and "Set up sync". The FAB is hidden here so the action is not duplicated (ChatGPT and Bluesky show one action; Claude uses the FAB alone).
- Say "Sync is optional. Everything works on this device without an account." in `bodySmall` under the buttons. This is Obsidian's framing, and it is the honest one for this product.
- After the first entry exists, show one dismissible card at the top of the list: "Tap a row to copy. Use the pencil to edit." Dismissal is remembered. Wispr Flow's snippet card shows that a single teaching card is enough.
- Filtered-empty and search-empty states are covered in 3.3. A locked or unavailable vault is not an empty state: secure rows still list, because names, keywords and tags are not secret.

### 3.11 Where iOS patterns must not be copied

| iOS pattern in the references or the current iPhone app | Android decision |
|---|---|
| Back chevron in a glass circle; swipe from the left edge | `ArrowBack` Up icon; system predictive back from either edge; never intercept back unless a transient state (selection, query) is active |
| Bottom search pill with filter and "+" beside it | Top `SearchBar`, chip row, FAB |
| "Cancel / Done / Save" text buttons in the navigation bar | Autosave; icon actions in `TopAppBar` |
| Long-press context menu with preview | Long-press enters selection mode with a contextual top bar |
| Multi-button swipe reveal | `SwipeToDismissBox`, one committed action per direction |
| Action sheets | `DropdownMenu` for short menus, `ModalBottomSheet` for the tag sheet only |
| Always-on "Copied" toast | Inline row confirmation; system clipboard overlay on API 33+; snackbar only below 33 or when it carries an action |
| Content inset by safe areas | Edge-to-edge is mandatory at target 36: lists scroll under transparent system bars; FAB, snackbar and last row take `WindowInsets` padding; `imePadding()` in the editor |
| Notification-style haptic patterns | One `Confirm` or `Reject` tick through the platform API |
| Capture-protected text rendering | `FLAG_SECURE` on the window while a secure body is visible |
| Segmented control pinned to the bottom of the editor | Single scrolling form |

---

## 4. Anti-patterns to avoid

1. Blocking copy confirmations: a dimmed screen with a centred card ([mymind](https://mobbin.com/screens/1010dd77-4098-42a1-bd6c-cb530d2da459?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) or a full blur ([Kraken](https://mobbin.com/screens/0023d9b8-22d5-44a8-88e4-b92cfbdafb3b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Copy happens dozens of times a day here.
2. Feedback on top of the content or the next action ([Formula 1](https://mobbin.com/screens/020891c5-f8d3-46c9-bf67-bc008d465148?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Finch](https://mobbin.com/screens/92e0e7df-346a-4827-bfd9-5be1ab7bf398?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
3. Snackbars that collide with floating bars ([Quo](https://mobbin.com/screens/28233f22-360a-456d-9973-ef2942fdf2fa?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Host them in the scaffold and respect insets.
4. Undo that contradicts its message ([Speechify](https://mobbin.com/screens/ce3ed5be-50c9-4b07-ba66-aa81a1ec1f03?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)), or a confirm dialog followed by no undo ([Udemy (flow)](https://mobbin.com/flows/96100ccd-1eba-4743-87f7-bc3a8bbeaaa4?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Pick one: undo for ordinary entries, confirm for secure ones.
5. Menus that list everything ([Evernote](https://mobbin.com/screens/e02408ee-1a3a-4218-9dcc-c26f09254741?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Keep each menu to six items or fewer, destructive last.
6. Ambiguous discard wording ([GoPro Quik](https://mobbin.com/screens/beed654c-76cd-4e1d-b533-038a3c4667d3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [5 Minute Journal](https://mobbin.com/screens/63d002c8-1ba7-48ac-8b03-8e52c32948fc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). The recommended autosave model has no discard dialog at all.
7. Illustrated dialogs for routine questions ([Gojek](https://mobbin.com/screens/302f5179-3aca-4211-8218-d89f081ce3eb?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Wrong weight and wrong tone.
8. Card or thumbnail lists for lookup ([Wispr Flow Scratchpad](https://mobbin.com/screens/b949802c-86cd-41ce-957b-2205b44b32d3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Bear](https://mobbin.com/screens/6bd7f900-5d0f-47d6-a706-5c34495a8dff?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Cloaked (web)](https://mobbin.com/screens/4aeb95f0-1b60-4f39-9006-f1541ce7d8b8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
9. Three or more trailing actions on every row ([Pocket](https://mobbin.com/screens/d915dbe8-b7ff-4518-8cb8-786f657dccbc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
10. Icon-only or pull-to-reveal search ([Bear](https://mobbin.com/screens/2e6b36e9-8e8d-4b4f-a2f0-58aa320177d0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Keep the field visible at all times.
11. Tri-state filter chips ([Character AI](https://mobbin.com/screens/0a4e712a-56c8-444b-ba82-602ea6ccb79e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) and Apply buttons for instant local filters ([Airwallex](https://mobbin.com/screens/c8a16042-c600-439b-9d23-91dda0ea985a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
12. Reading the clipboard unprompted ([MacroFactor](https://mobbin.com/screens/add6e4ed-369b-40a7-9334-2dd805da72dc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
13. Account-first first run ([Arc Search](https://mobbin.com/screens/90a48d5a-ac1c-49ff-b8d7-34898122ee42?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Brink](https://mobbin.com/screens/6e802e77-760d-4806-bdbe-05bf0a9a4639?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
14. Slide-over detail panels on wide screens ([NordPass (web)](https://mobbin.com/screens/f0e75746-817f-43cb-bb74-28d540fc31bd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Lightfield (web)](https://mobbin.com/screens/e7e29b92-a39d-4eb4-8d31-ac3ee2c01849?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).
15. Code text that wraps mid-token with no container ([Gemini](https://mobbin.com/screens/084aad68-f95f-49bb-914c-3889671090ad?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) or clips while scrolling sideways ([Cursor](https://mobbin.com/screens/ca182c85-0169-45a6-a3e3-a01f1bb01d54?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). Use a contained block with soft wrap.
16. Colour-only tag indicators. This one is from the current iPad sidebar, not from Mobbin: the two coloured dots per row carry no text. Do not port them.
17. Bullet masks for secrets in a list ([1Password's detail](https://mobbin.com/screens/517cf2c2-aad6-4007-a66a-c543c84d591e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) uses them in a detail field, where a reveal action sits beside them; in a list they only add noise).
18. Mascot or joke copy in empty and error states ([Discord](https://mobbin.com/screens/4806bd8c-4eab-4f57-9610-7163f5627c2e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)).

---

## 5. Open design questions

1. Row tap. The recommendation keeps tap = copy on phones (iPhone parity) with an edit button. Many Android users expect tap = open (Keep, most password managers). Should "Tap copies / Tap opens" be a setting, and what is the default?
2. Trailing button on phone rows: pencil (direct to editor, recommended) or overflow (Edit, Pin, Share, Delete)? The overflow adds reach to pin and delete without gestures but adds a tap to edit.
3. Keyword prefix. Android has no inline expansion, so `\` is a convention from the Mac. Show it for cross-platform recognition (recommended) or show the bare keyword? If the Mac prefix is configurable, which value does Android display?
4. "Keyword enabled" on Android. The flag only affects Mac expansion today. Does the editor show the switch for parity (recommended, low in the form) or hide it under the overflow?
5. Secure copy expiry. The Apple apps expire a secure copy after 60 s. Which mechanism is acceptable on API 28–36 (foreground timer plus clear, a short foreground service, or clear on next app resume), and what does the snackbar promise if clearing cannot be guaranteed?
6. Autosave for secure entries. Is debounce-autosave acceptable for an encrypted body, or do secure edits need an explicit "Save" inside the unlocked session? The answer decides whether a discard dialog exists anywhere in the app.
7. Search focus on launch: off by default as recommended, or on, accepting that the IME covers the pinned entries?
8. Default sort and whether Android records usage (for "Recently used" and ranking). The Mac has usage-based ranking; is that data synced or per device?
9. Tag colours under Material You. Keep deterministic per-tag hues (continuity with Apple apps) or go monochrome tonal labels (calmer, fully theme-driven)? The recommendation keeps hues but through tonal palettes.
10. Monospace face. System monospace (zero weight, varies by vendor) or a bundled face such as JetBrains Mono or Roboto Mono for keyword and body, for a consistent look and reliable glyph distinction (0/O, 1/l) in tokens?
11. Compact two-line list density: ship as a setting in the first release or wait for feedback?
12. Medium-width windows (600–839 dp, for example a foldable's inner screen in portrait): two panes with a 360 dp list, or single pane until 840 dp?
13. Swipe-to-delete on by default? It is fast and undoable for ordinary entries, but the library holds things people cannot recreate; pin-only swipe is the conservative alternative.
14. Android reference check. Mobbin has no Android screens. Before the design is frozen, someone should spot-check Bitwarden, Proton Pass, Google Keep and 1Password on a real Android device for the selection bar, search bar and snackbar behaviours assumed in section 3.

---

## Mobbin notice

---

**Your Mobbin AI usage is high this month**

Usage is unlimited during beta. If your usage stays at this level, you may need to purchase more credits once limits take effect. [View usage and plan options](https://mobbin.com/settings/billing-and-usage?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)

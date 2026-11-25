# Security and secret-handling UX: market research for Snippets Android

Research date: 2026-11-25. Source: Mobbin (MCP tools `search_screens` and `search_flows`). Mobbin offers only `ios` and `web`; every mobile pattern below was observed on iOS and is translated into Android and Material 3 terms in section 3. Descriptions are of what is visible in the returned screenshots, not of metadata.

## 1. Method

42 searches: 35 `search_screens` (34 iOS, 1 web) and 7 `search_flows`. All used the same task intent and `output_destination: "code"`. No personal or repository data was sent.

| # | Tool | Query | What came back |
|---|---|---|---|
| 1 | screens | password manager item detail with concealed field and reveal toggle | Opera and Muse credential details; otherwise thin. |
| 2 | screens | app lock screen with unlock using Face ID button | Almost only biometric *enrolment* screens (N26, Betterment, Dave). One real locked surface: Google Photos Locked Folder. |
| 3 | screens | crypto wallet secret recovery phrase display | Strong: Solflare, Phantom, Family, Brave, Coinbase Wallet, Uniswap, MoonPay, Binance. |
| 4 | screens | 1Password item detail | Strong: item view, revealed state, per-field menu, card item. |
| 5 | screens | Proton Pass login item detail | Dead end. Proton Pass is not in the library; got passkey lists. |
| 6 | screens | Bitwarden vault item view | Dead end. Unrelated detail screens; only CLEAR's vault item was useful. |
| 7 | screens | 1Password locked screen unlock | Lock screen, Face ID in progress, onboarding toggle, Security settings. |
| 8 | screens | security settings with auto-lock timer and biometric toggle | Strong: Quicken, Shopify, MoonPay, Trust Wallet, Coinbase Wallet, Up, Cash App. |
| 9 | screens | two-factor backup codes with copy and download | Strong: Expensify, Perplexity, Todoist, Family, Aave, Wealthsimple, Uber Eats, X. |
| 10 | flows | wallet recovery phrase backup with verification quiz | Phantom (two generations) and Family's 11-screen backup with quiz. |
| 11 | screens | import wallet, enter recovery phrase with paste button | Strong: Family, Glow, Trust Wallet, Phantom, Brave, Binance, Solflare, Uniswap. |
| 12 | screens | recovery key shown once, cannot be shown again | Warning interstitials (Glow, Phantom, MoonPay, Binance) and one-time codes (Aave, Family). |
| 13 | screens | locked note placeholder "this note is locked" | Apple Notes, Apple Photos Hidden, Snapchat My Eyes Only, CLEAR, Partiful. Half the results were paywall locks. |
| 14 | screens | list with locked items showing lock icon on rows | Mostly paywall and gamification locks; ClickUp and Todoist show a privacy lock. |
| 15 | flows | locking a note with password or Face ID | Apple Notes (10 screens), Tolan notebook and journal locks. |
| 16 | screens | authenticator app code list with countdown timer | Dead end for Authy / Google Authenticator. Riot Mobile's expiring code was the only timer. |
| 17 | screens | banking virtual card details revealed with copy and hide | Strong: Revolut, Wise, Lloyds, Afterpay, X Card, Dave, Venmo, Zing. |
| 18 | screens | copied to clipboard confirmation for API key or secret | Strong: Finch, CLEAR, Kraken, Glow, Wise, alias, Stake, Phantom. |
| 19 | flows | linking a new device by scanning a QR code | WhatsApp linking (8 screens), WhatsApp link-by-code, Telegram desktop link. |
| 20 | screens | approve sign-in from another device with matching code | Brave sync QR, Wise and Lloyds "check your other device", App Store 2FA code. No number-matching approval screen. |
| 21 | screens | linked devices list with link a device button | WhatsApp and Telegram; the rest unrelated "linked accounts". |
| 22 | screens | remove wallet confirmation, recovery phrase needed | Dead end for wallets; generic delete dialogs, with Monarch and CRED worth keeping. |
| 23 | screens | type to confirm destructive action | Notion, Copilot, Monarch, MoonPay, Fabric, Quo, Grailed, Photoroom. |
| 24 | screens | turn off end-to-end encrypted backup confirmation | Glow backup, Brave "Delete Sync Account", Finch and Coinbase Wallet "did you save it", Snapchat. |
| 25 | flows | turning on end-to-end encrypted backup with a key | Finch Advanced Data Protection, WhatsApp encrypted backup. |
| 26 | screens | screenshot blocked / capture not allowed notice | Mostly iOS screen-broadcast pickers (noise). Brave's "Screenshot detected" alert is the one find. |
| 27 | screens | hide content in app switcher, block screenshots toggle | X and XChat "Block screenshots" toggles. No app-switcher privacy screens: Mobbin does not capture the switcher. |
| 28 | flows | setting up a locked folder and moving items into it | Google Photos Locked Folder, Dropbox passcode, Freeform locked PDF. |
| 29 | flows | locking a chat with Face ID | WhatsApp chat lock, its intro sheet, and hidden locked chats with secret code. |
| 30 | screens | password manager passwords list | Google, Opera, Muse lists; Obsidian's Keychain secrets list. |
| 31 | screens | 1Password secret key / emergency kit | Emergency Kit screen and the sign-in options list. |
| 32 | screens | enter recovery key with invalid-key error | Solflare quiz error, Meta Quest 25-digit code, Nike, Fitbit, Resy, Glow soft warning. |
| 33 | screens | session expired, locked for your security | Dead end: account-suspension screens. Kept Setel's consequence list and Meta's re-auth sheet. |
| 34 | screens | verify security code, compare numbers with QR | WhatsApp security-code screen; 2FA setup-key screens. |
| 35 | screens | security checkup with status and recommendations | Messenger, Uber, Google, OKX, Chime, GoPay. |
| 36 | flows | password manager onboarding, creating a vault | Dead end for password managers; Obsidian "Configure your new vault", Cleo passkey intro. |
| 37 | screens (web) | API key created, copy now, not shown again | Strong: Coinbase, Cursor, ElevenLabs, AutoSend, Buffer, Grok. |
| 38 | screens | remove lock / turn off passcode confirmation | Passkey-removal dialogs (Wealthfront, Cash App, Chime, PayPal), Starbucks, Phantom. |
| 39 | screens | export private key warning, reveal with Face ID | Family, Fuse, Coinbase Wallet. |
| 40 | screens | GitHub mobile approve sign-in with digits | Dead end: GitHub web views only. Kept the "sudo mode" tip. |
| 41 | screens | MetaMask secret recovery phrase reveal | Dead end for MetaMask; same wallets as #3 plus a Uniswap variant. |
| 42 | screens | Dashlane / NordPass / LastPass secure note | Dead end. Apple Notes password fallback alert was the only new screen. |

Limits of this research:

- **Coverage.** Of the named password managers and authenticators, only 1Password is in Mobbin's iOS library. Bitwarden, Proton Pass, Dashlane, LastPass, NordPass, Authy, Google Authenticator, Standard Notes, Signal, MetaMask and Ledger returned nothing. Crypto wallets, banks and messengers carry most of the evidence.
- **Redaction.** Mobbin blurs or greys out secrets (seed words, card numbers, some codes). Layout and controls are visible; the typography of the secret itself often is not.
- **System UI.** The OS biometric sheet, the app switcher and clipboard overlays are not captured. Nothing here shows Android's `BiometricPrompt`; section 3 relies on platform knowledge for it.
- **Flows.** `search_flows` returns a flow URL and screen ids but no per-screen `mobbin_url`, so screens seen only inside a flow are cited by flow.

## 2. Pattern findings

### 2.1 Lock screens and unlock entry points

What the best apps do: the locked surface is nearly empty. One lock glyph, one sentence, one action. The app never draws its own biometric UI; its button hands over to the system. A typed fallback is offered in the same place, not behind a separate screen.

- [Apple Notes locked note](https://mobbin.com/screens/15f24a31-1d27-4f8b-bd23-185d21949980?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): grey padlock, "This note is locked.", a "View Note" text link; the toolbar and title area stay in place.
- [Apple Photos Hidden album](https://mobbin.com/screens/01f45e7a-2178-4ecf-9f80-8a8fc6a56bbf?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): padlock, "Use Face ID or Enter Your Passcode to View This Album", "View Album" link. The sentence names both methods.
- [Google Photos Locked Folder](https://mobbin.com/screens/fcd75ad4-24d9-49af-a3e3-c1edf8fb746c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): folder illustration, a single pill button "Open with Face ID", close button.
- [1Password lock screen](https://mobbin.com/screens/727498b4-7dfe-46d0-baf4-7766a1d1ee4e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): logo, account avatar, password field with a Face ID icon inside it, so both paths share one control.
- [Apple Notes password fallback](https://mobbin.com/screens/b5401fd5-f3be-4b8a-bde8-ab4896c0a784?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): alert "View Note: Enter your locked notes password." over the locked placeholder.

What fails: query #2 returned seven biometric *marketing* screens ("Faster login with Face ID", illustrations of padlocks) and one usable locked surface. Apps spend their design effort on the pitch and little on the locked state users see every day. A separate app password ([Apple Notes "Set Password" with hint field](https://mobbin.com/flows/6838fe06-6657-4d57-a9c0-d609354dfcdf?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Dropbox 4-digit passcode](https://mobbin.com/flows/e4c934bd-2d1c-4eb9-8c82-78ee0209cf2d?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) is a second secret to forget; Snippets uses the device owner's credential and should not add one.

### 2.2 Locked items in a list

What the best apps do: keep the row's shape and metadata, and replace only the preview.

- [Apple Notes list, in the locking flow](https://mobbin.com/flows/6838fe06-6657-4d57-a9c0-d609354dfcdf?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the locked note keeps its title and time; a small padlock precedes the title and the word "Locked" replaces the preview text.
- [Freeform locked PDF](https://mobbin.com/flows/3a67a616-47c4-473c-81de-95d858150567?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the thumbnail becomes a large grey padlock while file name, type and size stay readable. This is Snippets' model exactly: metadata visible, content sealed.
- [ClickUp "Personal List"](https://mobbin.com/screens/87655952-727a-42b6-8749-aa8d26cea0ef?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): trailing outlined lock on a private list.
- [Todoist project picker](https://mobbin.com/screens/47941a77-a1a0-49ff-bfbc-510f039a2549?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a small lock inline after the project name.
- [Obsidian Keychain](https://mobbin.com/screens/8137c9be-ffdb-453a-80eb-7157bfaa0b0d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): secrets list showing name and "Never accessed" instead of any value.

What fails: in consumer apps the lock icon mostly means "pay or earn to unlock" ([Wysa](https://mobbin.com/screens/c3aa23c1-0deb-450f-ba3e-82847b14e364?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Mimo](https://mobbin.com/screens/186bd603-676f-40f8-b7bf-e3026e99786e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)). A bare trailing lock on a greyed row reads as "unavailable". A secure row must look fully enabled and say "Secure" in words.

### 2.3 Secure item detail: concealed fields, reveal, copy

What the best apps do: concealed by default; reveal is a toggle whose label names the next state; copy is available *without* revealing; each field has its own copy control.

- [1Password item](https://mobbin.com/screens/2a538f7a-7027-448f-9d77-7d0a38555c0c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): labelled fields, password as dots with a strength mark, a "…" menu per field, tags and modified date below.
- [1Password field menu](https://mobbin.com/screens/f93aeb4d-8801-43e2-8613-32e160d3fc6e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): Copy, Reveal, Show in Large Type, Pin to Home. Copy comes first.
- [1Password revealed](https://mobbin.com/screens/e9a15a95-7c25-49ae-9224-ad818e4810d8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the password replaces the dots in place; nothing else on screen moves.
- [Revolut virtual card](https://mobbin.com/screens/74f597f0-182b-4bd5-b5ed-497a7e6e4eb0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): revealed number and CVV with small copy icons, a selected "Hide details" button, snackbar "Card number copied".
- [Wise card details sheet](https://mobbin.com/screens/6213349c-e296-4e77-96ad-57224a930cef?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): one row per value, each with a "Copy" pill.
- [CLEAR vault card](https://mobbin.com/screens/3c9f89d5-8e16-4f77-8cdd-1fe3f9f07907?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): frosted card with one "Show Details" button in the middle, the closest analogue to a locked multi-line body.

What fails: [Opera](https://mobbin.com/screens/a225040f-c244-4cd1-94a6-72fa447054bd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) shows an eye toggle with no copy action, so the user must expose the password to use it. [Dave](https://mobbin.com/screens/717a52bf-03d7-462b-9397-585bc430f64f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) uses a settings-style switch "Show card info" for a momentary reveal; a switch implies a lasting preference. Dots sized to the secret leak its length; dots are also wrong for a multi-paragraph note.

### 2.4 Copy feedback, timers and clipboard clearing

What the best apps do: confirm at the point of action, in a few words; show expiry as a depleting bar plus text; state the clipboard policy once, in settings.

- [Phantom address list](https://mobbin.com/screens/4d9778ed-2ba4-48d6-be47-e52696a05d14?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): toast "Address copied" and the tapped row's copy icon turns into a check mark.
- [alias setup key](https://mobbin.com/screens/05929b9e-8430-42a8-bf52-125e80bf8749?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): no toast; the key box itself changes to "SETUP KEY COPIED / PASTE INTO YOUR AUTHENTICATOR APP".
- [Riot Mobile authorization code](https://mobbin.com/screens/9c452965-105f-49b4-8b92-53258452e72d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): six large digits, a linear bar draining, "Code will expire in 28 seconds".
- [Brave sync code](https://mobbin.com/screens/53c3fdf5-a622-4484-aa67-8ed340ca85c0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): info box with a timer icon, "This temporary code is valid for the next 0 hour 29 min 48 seconds".
- [1Password Security settings](https://mobbin.com/screens/bc9ed919-274c-4923-96f1-b0865e556348?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Clear Clipboard" switch captioned "Automatically remove authentication codes or anything you copy from 1Password after 90 seconds", and a separate switch for copying to other devices.

What fails: no app surveyed shows the clipboard countdown *at the moment of copy*; users learn about clearing only if they visit settings. [Kraken](https://mobbin.com/screens/0023d9b8-22d5-44a8-88e4-b92cfbdafb3b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) confirms a copy with a full-screen blur that prints the whole copied string again. [Finch](https://mobbin.com/screens/92e0e7df-346a-4827-bfd9-5be1ab7bf398?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) lays its snackbar over the Continue button.

### 2.5 Marking an item secure, and reversing it

What the best apps do: the action sits with the item's other actions; the first use explains scope in one sheet; the confirmation states where the content will and will not exist afterwards.

- [Google Photos, move to Locked Folder](https://mobbin.com/flows/fb166ccd-4556-4a4b-bba4-2082063daba6?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): menu item "Locked Folder" with a lock; dialog "Move to Locked Folder? Photos & videos in Locked Folder on this device are hidden from elsewhere in Google Photos and other apps, and won't be backed up", Cancel / Move.
- [WhatsApp lock chat](https://mobbin.com/flows/a967ccdd-d26a-4b55-8fd2-70f62a051def?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a switch row "Lock chat: Lock and hide this chat on this device." Turning it on raises the OS credential screen.
- [WhatsApp lock chat intro sheet](https://mobbin.com/flows/9794b486-87ee-49e1-b8b3-340b3c09015b?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Keep this chat locked and hidden", two sentences, and the limit in small print: "This chat will not be locked on your linked devices."
- [Apple Notes lock](https://mobbin.com/flows/6838fe06-6657-4d57-a9c0-d609354dfcdf?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): Lock sits beside Pin in the overflow menu; a one-time alert explains how locked notes get hidden.
- [Tolan notebook lock](https://mobbin.com/flows/5e1f8ec9-64cb-4c3d-aebf-65c328011ce6?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): an open-padlock icon in the top bar becomes a closed one; first use asks one question with "Yes, enable Face ID" / "Maybe later".

What fails: no surveyed app explains the *reverse* well. Turning protection off is a silent switch flip ([Phantom "Disable authentication: Are you sure…?"](https://mobbin.com/screens/bedd0e09-9ff8-49fb-83b4-83adb154b198?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) names no consequence). For Snippets the reverse is the riskier direction: the body leaves the vault and becomes ordinary, synced, exportable text.

### 2.6 First-time setup and education

What the best apps do: explain at the moment of first use, in three short lines, with one primary action and an honest limit.

- [Snapchat My Eyes Only](https://mobbin.com/screens/90ad08f9-4f7c-4311-a0cb-618dd7324914?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): inline card in the empty tab: "Snaps you move here can only be seen after you enter a My Eyes Only passcode." Set Up, Learn More.
- [Family reveal sheet](https://mobbin.com/screens/64df54fb-4176-4fe6-a32d-d04ba60a3d4b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): three icon lines ("Keep your Secret Phrase safe", "Don't share it with anyone else", "If you lose it, we can't recover it"), Cancel / Reveal.
- [1Password Face ID step](https://mobbin.com/screens/5526155d-d09a-47df-b6dc-81892fac0d3b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): one switch, one line, one "Learn more" link.
- [Obsidian "Configure your new vault"](https://mobbin.com/flows/05ab6ea5-36d8-41f2-9e68-7e2bb7a3e831?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): one field and one button; a technical audience needs no illustration.
- [GitHub "sudo mode" tip](https://mobbin.com/screens/b95706f5-ea8e-4276-b5ab-40e019f37a88?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): one sentence explains the whole session model: you will only be asked again after a period of inactivity.

What fails: fear as education. [Binance](https://mobbin.com/screens/4ca06d9f-104e-449e-b034-b9d8a6e94d5f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) fills the screen with "Binance CANNOT access or retrieve it." in red capitals; [Glow](https://mobbin.com/screens/9ee79690-952d-4acd-9cf7-f4330a6fe55b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) opens with a red "Attention" page; [Phantom](https://mobbin.com/flows/1c019b72-1213-4f94-ae9d-b3dd5f0fbd78?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) stacks a warning page, a mandatory checkbox and then an "Are you sure you want to continue?" alert before showing the phrase.

### 2.7 Recovery key, recovery code and seed phrase display

What the best apps do: a dedicated screen, the secret in monospace inside its own container, grouped for transcription; Copy plus a file option; one sentence saying it is shown once; a primary button worded as the user's statement ("I've saved it"); when loss is unrecoverable, a light check that the user really has it.

- [Expensify recovery codes](https://mobbin.com/screens/b0644197-3e0d-4748-b673-71d9dcf4567e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): step label "Step 1 of 3", ten codes in a two-column monospace grid, Copy and Download buttons inside the code card, consequence stated in two plain sentences.
- [Aave backup code](https://mobbin.com/screens/af913d3b-ffe6-4a5a-acce-101f0abb15d0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): code card with "Copy Code", footnote "You'll only see this code once. Please store it somewhere safe.", primary "I've Saved My Code".
- [Coinbase API key (web)](https://mobbin.com/screens/73007b47-cdb2-452d-a4b4-d725d333e6c8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Keep your key safe … For security, it can't be re-downloaded. If lost, delete and create a new one." Monospace boxes with copy icons; primary "I've saved my key".
- [Cursor API key (web)](https://mobbin.com/screens/98d7136c-ced4-45b3-956d-a769565d2843?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Copy this key now as it won't be shown again." and "If you lose it, you'll need to create a new one." The remedy is stated next to the warning.
- [1Password Emergency Kit](https://mobbin.com/screens/5efb7b8b-bec2-4e54-99fe-fdd7ac7d2355?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Download PDF" as the primary action; a pale note says the kit holds a Secret Key "which we cannot access or recover for you".
- [Family backup with quiz](https://mobbin.com/flows/7da6f238-a2d6-4ab4-903a-e634c2c79829?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): status row "Not Backed Up" with "Back Up Now"; after the phrase, "Confirm Backup: Complete this quick test"; a wrong answer shows "Oops! That's incorrect."; the row then reads "Backed Up".
- [Solflare quiz](https://mobbin.com/screens/bec2a250-1e6c-45eb-a390-c31f8182ff86?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "What is the 7th word in your Recovery Phrase?" with six choices; the error suggests going back to check what was written down.

What fails:

- [Coinbase Wallet](https://mobbin.com/screens/1ee15840-dd9e-499f-a5ce-d297064ad555?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) ties "Yes, I saved my recovery phrase" to accepting terms and a privacy policy in one checkbox.
- [Finch](https://mobbin.com/screens/ca790f56-5e37-48c7-9106-da4eff2f629b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) asks "Have you saved this encryption key somewhere?" with Yes / No, where the highlighted button is "No". The user must read twice.
- [Uber Eats](https://mobbin.com/screens/5f5539f0-926e-4c17-be7e-8b2ef41b53f8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) tells users to "Screenshot these codes", which sends them to cloud photo backup. [Brave](https://mobbin.com/screens/8810857d-9f7f-4ae2-9194-938784811c5f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) has to warn about exactly that after the fact.
- [X](https://mobbin.com/screens/41511784-ee6b-46e3-b790-7286b260c9ff?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) prints the backup code as an ordinary paragraph under the heading "You're all set", with no copy control.
- The iOS Snippets app currently shows the recovery key inside an alert's message text. An alert cannot offer grouping, a file export or a confirmation step; do not port it.

### 2.8 Restoring from a recovery key

What the best apps do: one multi-line field with a Paste control next to it, a format hint under it, forgiving input, and errors that say which kind of wrong.

- [Trust Wallet restore](https://mobbin.com/screens/7477806c-29c7-4dab-ae2f-1e60de6db1a0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): text area with "Paste" inside it, helper "Typically 12 (sometimes 18, 24) words separated by single spaces", link "What is a secret phrase?".
- [Uniswap](https://mobbin.com/screens/02196456-308d-4683-87b9-622c172bcdfd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Your recovery phrase will only be stored locally on your device." above the field; Paste chip; "How do I find my recovery phrase?".
- [Family import](https://mobbin.com/screens/afda2873-755d-4b95-85cf-afa2df04b91a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Paste from Clipboard" is the primary control, "Input Manually" the secondary.
- [Meta Quest 25-digit code](https://mobbin.com/screens/8451ca13-4a88-4e1a-b3b4-a1154553e67d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): one field that formats itself into five groups with hyphens; inline error "This code doesn't exist. Check the email and try again."
- [Glow soft warning](https://mobbin.com/screens/ff164926-d31f-43a6-b097-94da6d87cd45?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): amber text "You are using words from a non-standard wordlist. Please make sure you have typed correctly." above a button that stays enabled.
- [WhatsApp link-by-code](https://mobbin.com/flows/77629de3-8144-4b73-a220-4a9e6039faca?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): eight boxes as 4 + 4 with a dash, and "Never enter a code if you didn't request it."

What fails: [Brave](https://mobbin.com/screens/851a8e7e-7f26-471e-9de1-6b2f372f95e2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) draws 24 separate fields and then has to explain that pasting into any of them works. Per-character boxes are fine for 6 to 8 symbols and poor for 27. Generic "Invalid code" errors ([Nike](https://mobbin.com/screens/5a8bda37-cd47-4c51-9363-9a79228f9b3e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)) do not separate a typo from a wrong key.

### 2.9 Security settings

What the best apps do: status first, then the lock rules as a plain sentence or short choice list, then credentials and recovery, with destructive actions last and apart.

- [1Password Security](https://mobbin.com/screens/bc9ed919-274c-4923-96f1-b0865e556348?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): unlock method tiles, "Require password: Every 2 weeks", "Auto-Lock on Exit: 2 minutes", clipboard and concealed-field switches, each with a caption.
- [Coinbase Wallet Security](https://mobbin.com/screens/4d21d6b0-61b6-4187-9264-86a6f2e5847f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): heading "Require unlock when…" with the rule "At least one option must be selected."
- [Cash App Security lock](https://mobbin.com/screens/956ee479-7071-4084-8621-da4c8e9cbc80?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the settings read as a sentence: "We'll ask for your Face ID or Cash App PIN when you: Move money / Unlock the app".
- [Glow Backup](https://mobbin.com/screens/c52c3321-c7da-4479-aaf4-186f2fb521d9?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): a "Keychain" section says where keys live and what survives a reinstall; backup status with date; the sheet adds "Neither Glow nor Apple can access your wallets."
- [OKX Security center](https://mobbin.com/screens/41f1ac07-80a5-4b8f-98af-c7f4400159e1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): each method row ends in its state ("Not enabled", "Not set up").
- [Finch Advanced Data Protection](https://mobbin.com/flows/521f6e5a-345e-452f-bce7-c247fd7aad54?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): status card, an "Encryption Key" row, and a red-text "Turn off…" at the bottom.

What fails: scores. [GoPay](https://mobbin.com/screens/daa43c24-d077-41ec-aab3-aa3bc6bd037f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) shows "40% Make it stronger" with "+20%" badges, and [OKX](https://mobbin.com/screens/41f1ac07-80a5-4b8f-98af-c7f4400159e1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) opens with a red "Your account is vulnerable" card. A user who chose not to add an optional recovery key is not "vulnerable".

### 2.10 Destructive and sensitive confirmations

What the best apps do: name the object, list what happens and what stays, say whether it can be undone and what the remedy is, and label the button with the verb.

- [Monarch "Delete connection"](https://mobbin.com/screens/4a659555-c1ce-4655-ac5c-301b8f1f4a03?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): two scopes as radio options, a "What will happen:" box with a cross for what stops and ticks for what remains, type-the-name confirmation, button "Delete permanently".
- [Brave "Delete Sync Account"](https://mobbin.com/screens/1cda0c93-6eff-4e74-96c6-73660aa8c866?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): three paragraphs: what is removed from servers, "It will not however delete the data that is stored locally on those devices", and what starting again takes.
- [Wealthfront "Delete passkey"](https://mobbin.com/screens/6598e107-a797-4def-b9a7-a10c730a6eee?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): consequence, a side effect elsewhere, and "You can create a new passkey anytime." Tonal red button, Cancel below.
- [Cash App "Remove passkey?"](https://mobbin.com/screens/3e8e666e-d15e-4d48-a65d-a5249ae35082?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): the sheet repeats the exact item being removed, with its date.
- [Notion workspace deletion](https://mobbin.com/screens/175805d3-c376-4434-ab7a-96ca1b4bbdf2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): type the workspace name; button "Permanently delete workspace".
- [Setel consequence list](https://mobbin.com/screens/6025aab4-e4aa-48e2-80a0-a5c8b774d46b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): five amber "will be…" lines, then one blue line for what "will not be affected".

What fails: [Buddy](https://mobbin.com/screens/7f3f83d0-3e8d-4347-afc4-28a53bd135b2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) asks "Are you sure you want to remove this wallet?" with No / Yes and nothing else. [CAVA](https://mobbin.com/screens/3c7d622a-198a-4690-9a78-5fcb0b2eb006?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) puts one centred 60-word paragraph under "ARE YOU SURE?". [Chime](https://mobbin.com/screens/f0670ae4-24e0-4dd7-b3c7-bb9b9022b889?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) colours "Delete passkey" in its brand green, and [PayPal](https://mobbin.com/screens/5ba5f05c-b635-4d95-bcb1-decc702a149f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) confirms a deletion with a green check-mark button that has no label.

### 2.11 Screenshot and capture protection

iOS cannot block screenshots outright, so apps there react or blank the field.

- [Brave "Screenshot detected"](https://mobbin.com/screens/8810857d-9f7f-4ae2-9194-938784811c5f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): after the fact, an alert warns that the screenshot "may get backed up to a cloud file service".
- [Binance seed phrase](https://mobbin.com/screens/2bdc07dc-c505-47b9-af9a-28ab036a3f26?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): in the capture the phrase area is blank while the "Hide" button and "Done" remain, consistent with a capture-protected field (or Mobbin redaction).
- [X "Screenshot settings"](https://mobbin.com/screens/9564d9e7-46b0-4f89-87cf-4d8d1a1a4e4b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "Block screenshots: Messages in this chat will not appear in screenshots." The caption describes the visible effect, not the mechanism.
- [Uniswap "View this in a private place"](https://mobbin.com/screens/90f37d77-8827-44ae-bf32-fb027b551049?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) and [Solflare "Make sure no one is watching"](https://mobbin.com/screens/fc570db7-1467-49f7-9c9e-415f5812ebac?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): shoulder-surfing gates before reveal.

What fails: reacting after the capture exists. No app-switcher privacy screens could be found (not captured by Mobbin); section 3 covers Android's behaviour from platform rules.

### 2.12 Device pairing and approval

What the best apps do: instructions name the place on the *other* device; the QR has a typed fallback; the code has a visible lifetime; the result is a named, revocable entry.

- [WhatsApp linking](https://mobbin.com/flows/dd21cacc-071a-4f4a-8813-ecf59e796ac7?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): Linked devices, a scanner headed with where to go on the other device, "Logging in… Keep WhatsApp open on both devices", "Link with phone number instead", then a device sheet with "Log out".
- [Brave sync QR](https://mobbin.com/screens/53c3fdf5-a622-4484-aa67-8ed340ca85c0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): segmented "QR Code | Code Words", steps for the second device, "Treat this code like a password…", QR, validity timer.
- [Telegram desktop link](https://mobbin.com/flows/16b7a729-ac06-451f-914e-0e6a76fda5f9?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): scanner with corner brackets and a torch button; afterwards a snackbar "Login Successful: Telegram Web" with a "Terminate" action and a new row under Active sessions.
- [WhatsApp "Verify security code"](https://mobbin.com/screens/b5acd7f8-fd6c-4ca3-ae13-4aef7c7117df?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): QR on a white disc, a 60-digit number as twelve groups of five on three lines, "scan this code … You can also compare the number above instead", "Scan code".
- [Lloyds "Check your other device"](https://mobbin.com/screens/eed622e1-aaeb-461e-9e32-e343a4237db6?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp): "It will expire in 5 minutes.", a note on order of steps, and "I haven't got a notification" as the way out.

What fails: [Wise](https://mobbin.com/screens/496d3823-f2d9-4926-9d8d-30e14a1baf4e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) shows "CHECK YOUR OTHER DEVICE" with no code to compare and no expiry. Brave's red warning sits between the instructions and the QR, where it reads as an error. No surveyed iOS app shows the approving side a comparison code together with the requester's name.

## 3. Recommendations for Snippets Android

Principles carried from the research:

1. Metadata is ordinary; only the body is special. Secure entries look like entries.
2. The app never draws authentication UI. It draws the button that leads to `BiometricPrompt` and the state before and after.
3. Every security surface says what happens to data on this device.
4. Use one accent for "secure" (the brand's orange shield-lock; define a `secure` colour role next to the M3 scheme) and never use the lock glyph for anything else.

### 3.1 Secure row in the library list

Same `ListItem` anatomy as an ordinary row: headline = name, supporting line = `\keyword · preview`, tag chips, trailing time. Only the preview differs:

```
Atlas API token                                   9:04 PM
\atlas-token · [lock 16dp] Secure
[work] [tokens]
```

- Replace the preview with a 16 dp `Icons.Outlined.Lock` in the `secure` colour and the word "Secure" in `onSurfaceVariant`. No dots, no blurred text, no fake length.
- Full contrast and full ripple: the row is enabled. The lock is never the only signal; the word carries it (TalkBack: "Atlas API token, secure, keyword atlas-token").
- The row never shows body text, even during a vault session. Search matches on name, keyword and tags highlight as on any row.
- The row's copy action runs secure copy (3.5). Row actions that secure entries do not support (duplicate, share, export) are omitted from the menu rather than shown disabled.
- Do not add a "Secure" filter tab or a separate vault section; a `FilterChip` "Secure" among the tag filters is enough.

### 3.2 Locked body placeholder in the editor

Name, keyword and tags stay as ordinary editable `OutlinedTextField`s. The body container keeps its size, shape and position and swaps its content:

```
Snippet
+--------------------------------------------------+
|                    [lock 32dp]                   |
|                  Body is locked                  |
|        Encrypted in the vault on this device.    |
|                 [   Unlock   ]                   |
+--------------------------------------------------+
Copy does not need Unlock. It asks each time.
```

- "Unlock" is a `FilledTonalButton`. The top app bar keeps a copy `IconButton`.
- After unlock the body appears in place in the monospace body style. The top app bar gains a `LockOpen` icon button in the `secure` colour (3.4).
- When the session ends while the editor is open, the placeholder returns with a reason line under the title: "Locked after 5 minutes without use.", "Locked after 30 minutes." or "Locked when you left the app." No dialog.
- No blur and no "peek". On lock the body leaves composition and memory, not just view.
- New entry with Secure switched on before a vault exists: start vault setup (3.6).
- No screen lock on the device: the placeholder reads "Set a screen lock to use secure snippets" with a `TextButton` "Open settings" (`Settings.ACTION_SECURITY_SETTINGS`). This state has no iOS counterpart and must be designed.

### 3.3 Where the biometric prompt is triggered

Trigger only from an explicit action, never on app launch or on opening an editor: Unlock, secure copy, switching Secure on or off, add or restore a recovery key, New Recovery Code, Replace Keys, approving a pairing request.

- Use `androidx.biometric.BiometricPrompt`. Allow strong biometrics and the device credential. On API 30+ that is `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`; the combination is not supported on API 28 and 29, where engineering needs a fallback path. The design must not assume a fingerprint is present: the same button serves PIN-only devices.
- With device credential allowed, the prompt has no negative button; the system supplies "Use PIN / pattern / password". Do not draw a "Use passcode" link of our own.
- Only title, subtitle and description are ours. Name the action and the object:

| Action | Title | Subtitle |
|---|---|---|
| Unlock | Unlock secure snippets | Stays unlocked while in use, 30 minutes at most |
| Secure copy | Copy "Atlas API token" | Clears from the clipboard after 60 seconds |
| Secure off | Turn off Secure for "Atlas API token" | The body will be stored unencrypted |
| New Recovery Code | Create a new recovery code | The current code stops working for new devices |
| Replace Keys | Replace library keys | Other devices must reconnect |
| Approve pairing | Approve sign-in | Code 4F7K-2QXM |

- Button labels say "Unlock" or the verb. Do not put a fingerprint or face icon on them: the modality is the system's business. A lock icon is acceptable.
- Cancelled prompt: return silently to the previous state. Lockout: show the system's message in a `Snackbar`; do not paraphrase attempt counts.

### 3.4 Session and auto-lock indication

- While a vault session is open, show a `LockOpen` `IconButton` in the `secure` colour in the top app bar of the library and the editor. Tap = lock now (no confirmation; a `Snackbar` "Vault locked"). Tooltip (`PlainTooltip`): "Vault unlocked. Tap to lock."
- No ticking countdown for the session; a clock on screen for 5 minutes is noise. The rules live in Settings and in the unlock prompt subtitle (GitHub's "sudo mode" tip is the model). Explain a lock after the fact with the reason line in 3.2.
- When locked, the icon is absent. Do not show a closed lock in the app bar; "locked" is the default and needs no badge.
- Leaving the app locks at once. On return there is no interstitial and no prompt.

### 3.5 Secure copy feedback and the 60-second clipboard

- Flow: tap copy, `BiometricPrompt` (every time), then haptic confirmation.
- Put the clip on the clipboard marked sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`, or its string key before API 33) so the system preview and keyboards mask it.
- Android 13+ shows its own clipboard overlay at the bottom of the screen. Do not add a "Copied" snackbar on top of it. Show the part the system does not know, the expiry, inside our own layout:

```
[check] Copied. Clears from the clipboard in 0:42        [Clear now]
[==============================--------------]
```

  This is a tonal `Surface` row directly under the body container (editor) or pinned under the search field (library), with a `LinearProgressIndicator` draining over 60 s. The copy icon shows a check for the same period (Phantom's pattern).
- API 28 to 32 have no system overlay: use a `Snackbar` "Copied. Clears in 60 seconds" with the action "Clear now", plus the same inline row.
- At expiry the row reads "Clipboard cleared" for three seconds and disappears. Say "cleared" only when Snippets cleared it. If the user copied something else meanwhile, remove the row silently and leave their clipboard alone.
- "Stays on this device" needs care on Android: the sensitive flag asks keyboards not to keep the clip in history, but OEM cross-device clipboards are outside our control. Say "Marked sensitive" in Settings rather than promising more than the platform gives.
- Read the clipboard only on an explicit Paste tap. Android 12+ shows a system toast whenever an app reads another app's clip; unprompted reads look like spying.

### 3.6 Vault setup

Contextual, at the first time Secure is switched on. One `ModalBottomSheet`, one system prompt, one recovery-key screen. No illustration, no carousel.

```
Secure snippets

[lock]   The body is encrypted on this device.
[search] Name, keyword and tags stay visible and searchable.
[timer]  Unlocked bodies lock after 5 minutes idle, after 30 minutes,
         and when you leave the app.

Uses your screen lock: fingerprint, face, PIN, pattern or password.

                               [ Not now ]  [ Set up ]
```

- "Set up" opens `BiometricPrompt`, creates the vault, then shows 3.7 with "Skip" allowed.
- When Git sync is the provider the vault belongs to the library and nothing is minted here. The sheet instead says "This library has its own vault. Enter the library's recovery code to use secure snippets on this device." and leads to 3.9.

### 3.7 Vault recovery key screen

Full-screen destination (not an `AlertDialog`), `FLAG_SECURE` on. The key format is fixed: 27 Crockford symbols shown as `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX`.

```
[X]  Recovery key

Save your recovery key
It restores secure snippets if this device's key is lost.
Snippets does not keep a copy and cannot show it again.
+--------------------------------------------------+
|              7K2M-9QXD-4FTR-HV3N                 |
|              P8WC-6YJA-B5G                       |
+--------------------------------------------------+
  [ Copy ]   [ Save as file ]   [ Print ]

Keep it away from this device: a password manager on
another device, or on paper.

                         [ Skip for now ]  [ I've saved it ]
```

- Key in an `OutlinedCard`, monospace, large, split 4 + 3 groups over two lines so no group breaks. Not selectable; Copy uses the sensitive, expiring clipboard of 3.5.
- "Save as file" uses the Storage Access Framework (`ACTION_CREATE_DOCUMENT`, plain text with the key, date and what it is for). "Print" uses `PrintManager`. Screenshots are blocked; these replace them.
- "I've saved it" is a `Button`; "Skip for now" a `TextButton`. No checkbox. Skipping is legitimate because a key can be added later from Settings.
- Back or X before either choice: `AlertDialog` "Leave without saving the key? The vault is ready. You can add a recovery key later in Settings." Leave / Stay.

### 3.8 Git recovery code screen (shown once, never stored)

Same layout as 3.7 with stricter rules, because every other device needs this code.

```
[X]  Recovery code

Save this library's recovery code
Other devices need it to join this library and open its
secure snippets. It is shown once and stored nowhere.
If you lose it, a connected device can create a new one.
+--------------------------------------------------+
|              3HVN-T7QC-9KXA-M2PD                 |
|              W6RF-8YBJ-E4G                       |
+--------------------------------------------------+
  [ Copy ]   [ Save as file ]   [ Print ]

Confirm you have it: type the last three characters.
[ _ _ _ ]

                                          [ Continue ]
```

- No skip. "Continue" enables when the last group matches (a three-symbol `OutlinedTextField`, capitals, no autocorrect). This is the light version of the wallet quiz: one check, no word-order game. A mismatch shows "Those are not the last three characters." and nothing else.
- State the remedy on the screen, as Cursor and Coinbase do. Fear is not needed when a remedy exists.
- Never log, never restore from saved state, never keep in a `ViewModel` beyond the screen. On process death the screen cannot come back: show "The recovery code was not confirmed. Create a new one in Sync settings."
- New Recovery Code and Replace Keys end on this same screen.

### 3.9 Restore and join: entering a key or code

```
[<]  Restore with recovery key

Enter the recovery key created when Secure Snippets was set up.
It is checked on this device and not sent anywhere.

+ Recovery key -----------------------------------+
| 7K2M-9QXD-4FTR-HV3N-P8WC-6Y                [paste]|
+--------------------------------------------------+
  22 of 27 characters

                                          [ Restore ]
```

- One `OutlinedTextField`, monospace, capitals, autocorrect and suggestions off, a visual transformation that inserts hyphens every four symbols, a trailing paste `IconButton`. Not 27 boxes.
- Accept everything the decoder accepts: lower case, spaces, missing or odd dashes, `I` and `L` read as `1`, `O` as `0`. Never reject for formatting.
- Supporting text is a live counter until 27. Errors use the field's error state with a distinct sentence per cause:

| Cause | Supporting text |
|---|---|
| Too short or long | A recovery key has 27 characters. This one has 23. |
| Character outside the alphabet | "U" is not used in recovery keys. |
| Check symbol fails | There is a typo in this key. Compare it with your copy. |
| Well-formed, does not open the vault | This key is valid but belongs to a different vault. |
| Git code for a replaced library | This library's keys were replaced. Use the newest recovery code. |

- "Restore" stays enabled once 27 symbols are present; validate on tap, keep the text.
- State what a successful restore does before the user commits: "Secure snippets on this device become readable again. Ordinary snippets are not changed."

### 3.10 Security settings layout

Settings > Secure Snippets. M3 list with section headers; status first.

```
Secure Snippets

STATUS
  Vault             Unlocked                    [ Lock now ]
  Key storage       Android Keystore, hardware-backed
  Recovery key      Added 12 Nov 2026
LOCKING
  Locks after 5 minutes without use, after 30 minutes,
  and when you leave the app.
COPYING
  Secure copy asks every time. The clipboard entry is marked
  sensitive and cleared after 60 seconds.
SCREEN
  Secure bodies and recovery keys do not appear in screenshots,
  screen recordings or the recent-apps preview.
RECOVERY
  Add recovery key                                        >
  Restore with recovery key                               >
```

- Fixed rules are prose (Cash App's sentence style). Do not render disabled switches or a greyed timer picker for values the user cannot change.
- Status values are plain words in `onSurfaceVariant`: "Not set up", "Locked", "Unlocked", "Not added". No score, ring or "at risk" banner. A missing optional recovery key is a neutral fact with an action beside it.
- "Key storage" tells the truth for this device (hardware-backed, StrongBox, or software) and explains loss on tap: "The key stays on this device and is removed when the app is uninstalled. A recovery key lets you restore."
- "Lock now" is a `TextButton` in the status row, visible only while unlocked.
- Git-owned vault: the RECOVERY section is replaced by one row leading to Sync settings ("This vault belongs to your Git library. Its recovery code is managed in Sync.").
- Destructive actions (Replace Keys, Disconnect) live in Sync settings at the bottom under their own header, in `error` colour text, each opening 3.11.

### 3.11 Destructive and sensitive confirmations

Template (M3 `AlertDialog`; a full-screen dialog when there are more than three consequence lines): title = verb + object as a question; body = what changes, what stays on this device, whether it can be undone; confirm = the verb, never "OK" or "Yes"; dismiss = "Cancel". The bodies below are proposed wording and must be checked against what each operation does in the Kotlin port. The confirm is a `TextButton` in `error` colour for irreversible actions. Authentication is the friction: `BiometricPrompt` follows the confirm tap, so no type-to-confirm field is needed.

| Action | Title | Body | Confirm |
|---|---|---|---|
| Secure off | Turn off Secure for "Atlas API token"? | The body moves out of the vault and is stored as ordinary text. It will be included in search, sync, export and sharing. | Turn off |
| Delete secure entry | Delete "Atlas API token"? | The encrypted body is deleted from this device and, when sync is on, from your other devices. This cannot be undone. | Delete |
| New Recovery Code | Create a new recovery code? | New devices will need the new code. Devices already connected keep working. The old code stays in the repository's history, so this does not revoke a leaked code. | Create code |
| Replace Keys | Replace this library's keys? | A new library key, vault key and recovery code are created. Snippets on this device are kept and re-encrypted. Every other device stops syncing until it reconnects with the new code. This cannot be undone. | Replace keys |
| Disconnect Git | Disconnect from this repository? | Sync stops. All snippets stay on this device. The repository is not changed. Reconnecting may ask for the recovery code. | Disconnect |
| Restore over an existing vault | Restore with this key? | Secure snippets that this key cannot open stay locked. Nothing is deleted. | Restore |

Replace Keys gets the full-screen form with a "What happens" list in Monarch's style: one line per effect on this device, on other devices and on the repository, and one "not affected" line for ordinary snippets.

### 3.12 FLAG_SECURE behaviour

- Set `FLAG_SECURE` on the activity window while any of these is on screen: an unlocked secure body, a recovery key or recovery code, a restore field with input, a pairing QR or confirmation code. Clear it otherwise, so the library and ordinary editors stay screenshot-friendly (names and keywords are not secret; users file bug reports).
- Dialogs, bottom sheets and popups are separate windows: set `SecureFlagPolicy.SecureOn` (or inherit) on `DialogProperties`, `PopupProperties` and `ModalBottomSheetProperties` wherever such content can appear.
- With the flag set, the recent-apps preview is blank for that screen. Because the vault also locks on leaving the app, the user returns to the placeholder.
- No in-app "screenshot detected" alert. Android prevents the capture; the system tells the user. Do not copy Brave's reactive alert.
- Mark secure body composables as sensitive content on Android 15+ so they are hidden during screen sharing even when the flag state lags.
- Say it once, in Settings (3.10), in terms of the visible effect.

### 3.13 QR pairing and approval (Snippets Cloud "Sign In with Another Device")

New device (requester):

```
[<]  Sign in with another device

1. On a device that is already signed in, open
   Settings > Sync > Approve a device.
2. Scan this code.
+------------------------+
|        [ QR ]          |      white card in both themes
+------------------------+
Check that the other device shows this code
            4F7K-2QXM
[============----------]  Expires in 4:12
Waiting for approval…

[ Copy code instead ]            [ Cancel ]
```

Approving device, after scanning:

```
Approve sign-in?
Pixel 9 wants to sign in and receive this library's key.

The other device must show this code
            4F7K-2QXM
If you did not start this on a device you hold, deny it.

                                   [ Deny ]  [ Approve ]
```

- Requester: `LinearProgressIndicator` plus text for the server-issued expiry (Riot, Brave). At expiry the QR is replaced by "This code expired." and a "New code" button; never leave a dead QR on screen.
- The confirmation code is the anchor on both sides: large, monospace, grouped, with the same sentence structure. The device name is a label the requester chose; present it as a claim ("wants to sign in"), not as verified fact.
- "Approve" leads to `BiometricPrompt` with the code in the subtitle (3.3). "Deny" has equal visual weight (`OutlinedButton` vs `Button`), unlike iOS alerts that bold one.
- Scanner: full-screen camera with corner brackets, a torch toggle, a one-line header naming where to find the code, and "Paste code instead" for the copyable payload.
- After approval: `Snackbar` "Pixel 9 signed in" on the approver; the requester moves on to the first sync. Both screens are `FLAG_SECURE`.
- Reuse this comparison layout for SSH host-key fingerprints in Git setup: fingerprint in grouped monospace, the sentence "Compare with the fingerprint your host publishes", Trust / Cancel. A changed host key is a blocking screen, never a snackbar.

### 3.14 iOS patterns that should not be copied to Android

| Seen on iOS | Why not | Android / M3 instead |
|---|---|---|
| Face ID glyph on buttons ("Reveal", "Show recovery phrase") | Modality is unknown on Android and may be PIN only | Verb label, optional lock icon; the system prompt shows the modality |
| Alert with the secret or a text field inside it | No grouping, export or validation | Full-screen destination or full-screen dialog |
| Action sheet with a red row at the bottom | Not an M3 pattern | `AlertDialog` with verb-labelled text buttons |
| Custom in-app PIN pad and separate app password | A second secret to lose | Device credential through `BiometricPrompt` |
| Top "pill" toasts for "Copied" | Collides with status bar and Android 13 clipboard UI | Inline state change, `Snackbar` only before API 33 |
| "Screenshot detected" alert | Reactive | `FLAG_SECURE`, described once in Settings |
| Blur over the secret as the locked state | Blur is decoration, not protection, and costly before API 31 | Do not compose the secret; draw a placeholder |
| Bottom-pinned segmented "Content / Details" switch, floating glass circle buttons | iOS 26 idiom | `TopAppBar` actions; tabs or a single scrolling editor |
| Mandatory checkbox plus Continue plus "Are you sure?" alert | Three gates for one decision | One explanation, one verb button, then authentication |

## 4. Copy guidelines

Tone: calm, exact, short. A technical reader should be able to predict the code path from the sentence.

1. Say what happens, then what stays. "Sync stops. All snippets stay on this device."
2. Name the object. "Copy "Atlas API token"", not "Copy item".
3. Use the product's fixed terms: Secure (adjective on an entry), vault, vault session is internal (say "unlocked"), recovery key (vault), recovery code (Git library), screen lock (not "biometrics"), this device.
4. Numbers are facts: "60 seconds", "5 minutes", "30 minutes", "27 characters".
5. Pair every "cannot" with the remedy. "Snippets cannot show it again. You can add a new recovery key in Settings."
6. Buttons are verbs that match the title. Never "OK", "Yes", "Continue" for a destructive step.
7. No capitals for emphasis, no exclamation marks, no "Oops", no "Attention", no "for your security".
8. Do not claim more than the platform gives ("marked sensitive", not "invisible to other apps"; "hidden from screenshots", not "cannot be captured").
9. Errors say which kind of wrong and keep the user's input.

Example strings:

| Moment | String |
|---|---|
| Auto-lock reason | Locked after 5 minutes without use. |
| Background lock reason | Locked when you left the app. |
| Secure copy, then expiry | Copied. Clears from the clipboard in 1:00 / Clipboard cleared |
| Secure switch helper | Encrypts the body. Name, keyword and tags stay visible. |
| No screen lock | Set a screen lock to use secure snippets. |
| Recovery key intro | It restores secure snippets if this device's key is lost. |
| One-time display | Snippets does not keep a copy and cannot show it again. |
| Git code intro | Other devices need it to join this library and open its secure snippets. |
| Typo in key | There is a typo in this key. Compare it with your copy. |
| Wrong key | This key is valid but belongs to a different vault. |
| Keys replaced elsewhere | This library's keys were replaced on another device. Reconnect with the newest recovery code. Snippets on this device are kept. |
| Pairing warning | If you did not start this on a device you hold, deny it. |
| Screenshots | Secure bodies do not appear in screenshots or screen recordings. |
| Key storage | The key stays on this device and is removed when the app is uninstalled. |

## 5. Anti-patterns to avoid

1. **Fear as onboarding.** Red capitals and "Attention" pages before the user has done anything: [Binance](https://mobbin.com/screens/4ca06d9f-104e-449e-b034-b9d8a6e94d5f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Glow](https://mobbin.com/screens/9ee79690-952d-4acd-9cf7-f4330a6fe55b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
2. **Stacked gates.** Warning page, checkbox, then a system alert asking again: [Phantom](https://mobbin.com/flows/1c019b72-1213-4f94-ae9d-b3dd5f0fbd78?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
3. **Consent bundling.** "I saved it" merged with legal acceptance: [Coinbase Wallet](https://mobbin.com/screens/1ee15840-dd9e-499f-a5ce-d297064ad555?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
4. **Yes / No on a question the user must re-read.** [Finch](https://mobbin.com/screens/ca790f56-5e37-48c7-9106-da4eff2f629b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Buddy](https://mobbin.com/screens/7f3f83d0-3e8d-4347-afc4-28a53bd135b2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Shipt "Yes / No thanks"](https://mobbin.com/screens/fd04f3f6-ee98-4c4a-9da4-345d279165ce?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
5. **Destructive buttons in a friendly colour or without a label.** [Chime](https://mobbin.com/screens/f0670ae4-24e0-4dd7-b3c7-bb9b9022b889?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [PayPal](https://mobbin.com/screens/5ba5f05c-b635-4d95-bcb1-decc702a149f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
6. **Wall-of-text confirmations.** [CAVA](https://mobbin.com/screens/3c7d622a-198a-4690-9a78-5fcb0b2eb006?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
7. **Advising screenshots of secrets.** [Uber Eats](https://mobbin.com/screens/5f5539f0-926e-4c17-be7e-8b2ef41b53f8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
8. **Reveal without copy, or a settings switch for a momentary reveal.** [Opera](https://mobbin.com/screens/a225040f-c244-4cd1-94a6-72fa447054bd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Dave](https://mobbin.com/screens/717a52bf-03d7-462b-9397-585bc430f64f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
9. **Echoing the secret in the copy confirmation.** [Kraken](https://mobbin.com/screens/0023d9b8-22d5-44a8-88e4-b92cfbdafb3b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
10. **One field per symbol for long keys.** [Brave](https://mobbin.com/screens/851a8e7e-7f26-471e-9de1-6b2f372f95e2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
11. **Security scores and "vulnerable" banners.** [GoPay](https://mobbin.com/screens/daa43c24-d077-41ec-aab3-aa3bc6bd037f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [OKX](https://mobbin.com/screens/41f1ac07-80a5-4b8f-98af-c7f4400159e1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
12. **Lock icon for "pay to unlock".** [Wysa](https://mobbin.com/screens/c3aa23c1-0deb-450f-ba3e-82847b14e364?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp), [Slopes](https://mobbin.com/screens/b96a5910-c15b-4d83-a154-8004220b96b9?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp). Snippets has no paywall, so the glyph can mean one thing only.
13. **Pairing with no code and no expiry.** [Wise](https://mobbin.com/screens/496d3823-f2d9-4926-9d8d-30e14a1baf4e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp).
14. **Biometric marketing screens.** Seven of eight results for "app lock screen" were pitches such as [Vivid](https://mobbin.com/screens/a32b3e69-b77b-49a7-8265-818f3644194c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp). Snippets has nothing to sell here; setup is one sheet.

## 6. Open design questions

1. **Primary tap on a secure row.** iPhone copies on tap. On Android, does a tap open the editor (placeholder) with copy as a row action, or copy directly after authentication? This decides whether the library ever triggers `BiometricPrompt` on a single tap.
2. **Unsaved secure edits at auto-lock or backgrounding.** Is the draft kept encrypted and offered back after unlock (as on Linux), or discarded? The reason line in 3.2 needs a second sentence either way.
3. **Clipboard expiry when the process dies.** Can the 60-second clear be guaranteed after the user switches apps? If not, the copy must say "Snippets clears it after 60 seconds while it is running", or we need a short foreground mechanism.
4. **Countdown while the user is in another app.** The inline countdown is invisible exactly when it matters. Do we want an optional silent notification with "Clear now" (needs the notification permission on Android 13+), or accept silence?
5. **API 28 and 29 authentication.** Strong biometric plus device credential is not available as one prompt there. Which fallback does engineering choose, and does it change any visible string?
6. **Confirmation step for the vault recovery key.** This document recommends plain acknowledgement for the optional vault key and the last-group check for the Git code. Should both use the same step for consistency?
7. **Export formats for keys.** Is a plain-text file via the system file picker acceptable (it may land in a synced folder), and is printing in scope for v1?
8. **Screenshots of the library.** This document leaves the list and ordinary editors capturable. Should there be a setting to block capture app-wide?
9. **TalkBack and secure bodies.** iOS excludes revealed secure bodies from the accessibility tree. Do we mirror that on Android, or restrict to accessibility tools only (API 34+) so screen-reader users can still read their own secrets? Related: should the secure body field ask the keyboard for no personalised learning and no suggestions, at the cost of harder typing for long notes?
10. **"Secure" accent colour.** The brand's orange shield-lock versus an M3 scheme role (dynamic colour may produce an orange primary and remove the distinction).
11. **Pairing.** A Play services scanner is the least work but excludes de-Googled devices, which this audience uses: bundle a scanner? And do we show the requester's self-reported device name at all, given it cannot be verified, or only the confirmation code?
12. **Evidence gap.** Bitwarden, Proton Pass and the Android clients of every app were not available. A short manual review of Bitwarden and Proton Pass on Android is worth doing before DESIGN.md is final.

## Mobbin notice

---

**Your Mobbin AI usage is high this month**

Usage is unlimited during beta. If your usage stays at this level, you may need to purchase more credits once limits take effect. [View usage and plan options](https://mobbin.com/settings/billing-and-usage?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)


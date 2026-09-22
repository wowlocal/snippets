# Persistent diagnostics

Snippets writes structured JSON Lines through CocoaLumberjack on macOS and iOS/iPadOS.
The app keeps at most 14 days, rolls at 1 MiB or 24 hours, retains at most 64
archives, and caps the log directory at 24 MiB. The diagnostics directory is excluded
from backup; directories use owner-only permissions, files use owner read/write, and
iOS files use complete-until-first-authentication data protection.

Each line is schema version 1 and contains a UTC timestamp, process-session ID,
monotonic elapsed time, sequence, severity, category, event name, and a closed set of
event-specific fields. Export prepends a `diagnostics_manifest` line and validates every
source line. Only a torn final line may be skipped.

On macOS, `cloud_environment` comes from the running signed process's entitlement. The
iOS SDK has no public runtime API for reading that entitlement, so device logs report it
as `unrecognized` (and simulator logs as `absent`) rather than guessing from the source
plist. For an iOS sync-environment investigation, inspect the built app's signed
entitlements as described in `AGENTS.md` or use the validation in `install-ios.sh`.

The event API cannot accept snippet bodies, display names, tags, paths, record IDs,
ciphertext, keys, arbitrary error descriptions, or `NSError.userInfo`. Errors are reduced
to a known family and numeric code. Secure-snippet keywords are explicitly approved
metadata; they are normalized and bounded to 256 UTF-8 bytes.

Snippets Cloud native email login uses two events in the `sync` category:

- `cloud_sign_in`: a closed stage and outcome, elapsed milliseconds (bounded to one
  day), an optional saved-session-present boolean, and a classified failure reason
  with the sanitized error family/code. Stages cover local preflight, credential
  cleanup, discovery, saved-session checks, `email_code_send`, `email_code_verify`,
  credential journaling, library selection, commit, and post-login library setup.
  There is one terminal result per attempt. If cleanup masks the original error,
  the terminal record retains the original failing stage and cause.
- `cloud_sign_in_request`: one outcome per discovery, email-code start, or code
  verification request, with a closed endpoint kind, duration, optional HTTP status
  (100–599), and classified transport/response/JSON failure. Native reasons include
  invalid email/code, expired code, exhausted attempts, and rate limiting. This
  records the cause before user-facing error mapping; background refreshes do not
  emit this trace. Email addresses, codes, challenge IDs, and tokens are never logged.

The native email sheet opens before network work. To investigate a failure, find
its terminal `cloud_sign_in` and preceding request records in the same process
session. A saved-session authority mismatch identifies the failed comparison
without recording either value. A missing terminal result alone does not prove a
crash; correlate it with lifecycle/MetricKit diagnostics or the device crash report.

Exports still accept historic browser stages and `cloud_sign_in_presentation_anchor`
so retained logs remain readable. These are no longer emitted by native sign-in.
Terminal failures request synchronous persistence; ordinary progress and request
records remain asynchronous. Process-session sequence and timestamps supply
ordering; there are no account, device, or authentication request IDs.

No email addresses, authorization/verification codes, tokens, state, nonce, PKCE
values, issuer/server/callback URLs, HTTP headers, or response bodies enter these
events. Export privacy copy on both platforms describes the added fields.

CloudKit ordering is recorded through `cloudkit_sync_event` and
`cloudkit_scheduler_transition`. The former records only the closed callback kind, aggregate record
count, fetch nesting depth, whether a submit overlapped, whether the scheduler epoch is a full
resync, and whether that state update sealed a durable generation. The latter records closed
scheduler actions and reasons plus total and not-yet-published generation counts. Initialization
is recorded before the scheduler starts, so the first automatic callback cannot precede that
baseline. Together their process sequence reconstructs state-update/fetch/send races without
persisting record identifiers, opaque CKSyncEngine serialization, account identifiers, snippet
metadata, or ciphertext.

The `secure_editor_transition` event explains iPhone and iPad reveal behavior without
identifying a snippet. It records only the editor surface, the closed reveal-policy states
before and after the transition, a closed cause such as `store_refresh_remote_sync`,
`app_will_resign_active`, `scene_capture_changed`, or `renderer_failed`, and whether the
vault session was `no_key`, `locked`, or `unlocked`. No-op policy updates are omitted so
protected renderer refreshes caused by typing, selection, scrolling, or layout do not
become a high-frequency log.

Direct Accessibility replacement on macOS emits one `accessibility_replacement` terminal
record when the attempt ends without clipboard fallback, independently of verbose logging.
Its base fields are `outcome` (`delivered`, `rejected`, `ambiguous`, or `unavailable`) and
`duration_ms` bounded to 0–600,000. `delivered` means the direct write path accepted the
operation and verified the exact resulting value against the planned replacement; it is
not a keyboard-paste acknowledgement. `rejected` means a trigger mismatch or pre-text
validation failure aborted the insertion; the latter may already have changed the selection.
`ambiguous` means a text-bearing AX write was attempted without a confirmed result, so no
fallback edit is safe. New records include the complete optional group
`text_write_attempted` (boolean) and `selection_restoration` (`not_needed`, `restored`,
`skipped_context_changed`, or `failed`). This distinguishes a selection-only cancellation
from an uncertain text write and reports conservative pre-text selection cleanup. No rollback
is attempted after a text-bearing write. Older records without both fields remain exportable;
partial groups, unknown outcomes, and wrong types are rejected. An attempt proceeding to clipboard fallback
instead includes its AX outcome in that attempt's `paste_delivery` record, avoiding a
duplicate terminal event. Direct AX records are asynchronous, informational for delivered
writes and warnings otherwise, and include no text, selection coordinates, or identities.

Clipboard insertion on macOS emits one `paste_delivery` record per attempt, independently
of verbose logging. Its base fields are `outcome`, `restoration`, `duration_ms` (bounded to
0–600,000), and `had_fingerprint` (whether Accessibility supplied a baseline). Outcomes are
`interrupted`, `dispatched`, `clipboard_unavailable`, `event_creation_failed`, `text_observed`, `timed_out`,
`target_changed`, `pasteboard_superseded`, and `secure_input_enabled`. Restoration is separately
`not_borrowed`, `restored`, `superseded`, or `pending`: returning the clipboard does not prove
insertion. `text_observed` means the caret advanced and changed text matched the bounded replacement tail in the
original focused element; it is an Accessibility observation, not a receiver acknowledgement.
`dispatched` means the clipboard-history shortcut was sent; it does not claim that the
receiving app changed text. History keeps the chosen entry on the current clipboard and
finishes immediately after dispatch, without waiting for readback or restoring an older
copy. Its normal record has `restoration: not_borrowed`, `had_fingerprint: false`,
`paste_posted: true`, and `transport: clipboard_history`. This informational event is
asynchronous and carries no entry content or identity. Only pre-dispatch failures show
an error to the user.

New records also include `stage`, `reason`, `planned_deletes`, `delete_attempts` (both
bounded to 0–10,000), and `paste_posted`. Stages identify preflight, event preparation,
clipboard acquisition, selection preparation/validation, trigger deletion, the pre-paste
wait/check, dispatch, or confirmation.
Reasons are closed categories for context invalidation (unmarked key-down, pointer
interaction, application activation, monitor restart, or other context change),
quitting, a new expansion, stopped listening, secure input, target changes, event creation failure,
clipboard acquisition failure/supersession, unavailable/rejected/changed selection,
changed trigger, unavailable target, confirmation timeout, or no failure.
Delete attempts count synthetic key dispatch attempts, not acknowledged host edits.
`unmarked_key_down` does not distinguish physical typing from another tool's synthetic
input. Clipboard supersession does not identify the writer. No key codes, modifier
values, clipboard contents, process identifiers, or application identities are added.

Clipboard attempts can include the complete group `transport`, `selection`, and
`selection_restoration`. Transport is `insertion_only`, `clipboard_history`, `selection_paste` (one paste
over a verified trigger selection), or `backspace_paste` (legacy deletion fallback).
Selection is `unavailable`, `verified`, or `rejected`; its restoration is `not_needed`,
`restored`, `skipped_context_changed`, `failed`, or `timed_out`. These fields show which path was
attempted and whether an unpasted selection was safely restored, without recording
selection coordinates, selected text, or a field identity. The selection route sends
no synthetic deletes, so its `delete_attempts` remains zero.

Selection-paste records additionally carry one complete, optional group: `selection_phase`
(`original_validation`, `selection_request`, `confirmation`, `final_validation`),
`selection_observation` (`not_read`, `original`, `replacement`, `range_changed`,
`text_changed`, `unavailable`), `selection_write_attempted` (boolean), `selection_polls`
(0–40), and `selection_wait_ms` (0–600,000). These describe the final proof and aggregate
confirmation wait, not individual AX reads. They distinguish rejection before the setter,
pending browser acknowledgement, a real conflict, and loss of proof after baseline capture.
`selection_confirmation_timed_out` is distinct from a timeout after Cmd+V.

The selection setter is sent once. Its unchanged original range or temporarily unreadable
AX cache can be polled for up to 400 ms; an unrelated range or changed text aborts immediately.
The final exact proof and context/clipboard checks still precede paste without an intervening
await. Cleanup also waits for a pending selection before restoring it once and confirming the
restore. A stale original-range reply alone cannot establish `not_needed`; unacknowledged
cleanup is `timed_out`. No text is deleted, pasted, or retried on a failed selection proof.
All fields remain content-free and are recorded without enabling verbose Accessibility logs.

For opt-in GUI regression verification, run `./scripts/test-selection-paste-browser.sh`.
It temporarily focuses an isolated Chrome profile with synthetic input, textarea and
contenteditable fields, exercises the shipping selection transaction/clipboard lease,
and checks the real DOM/input-event model and selection rollback. It requires Chrome
plus Accessibility/post-event permission for the terminal. It does not open the user's
browser profile or Snippets library; the borrowed clipboard is restored while owned.

Optional `ax_replacement_outcome` records the preceding direct Accessibility attempt
as `unavailable`, `delivered`, `rejected`, or `ambiguous`. Optional
`interruption_origin` classifies an unmarked event as `unspecified`, `own_process`, or
`other_process`. It is derived from the source-process relationship and never includes
the PID or application name. An own-process event may have lost its marker; this field
does not prove which tool modified it. Neither a missing source nor another process
proves physical user input, and these classifications do not relax interruption checks.

The stopping reason is captured before clipboard cleanup; `restoration` independently
reports the cleanup result. Records remain one asynchronous outcome per attempt, except
pending restoration retains its existing synchronous policy. Export accepts old records
without progress or the newer optional fields, but rejects incomplete progress or
transport/selection or selection-confirmation groups, unknown enum values, and wrong types. The optional origin
and Accessibility outcome fields require the complete progress group.

For snippet insertion, an unreadable or nonmatching field keeps the loan for the full
1.2-second confirmation budget. Clipboard history does not take a loan or enter this wait.
Timeouts stay unconfirmed in both UI and diagnostics and do not count as snippet usage.
There is no automatic insertion retry. A focus-element change prevents confirmation and
drains the bounded window; app switches, secure input, and a new clipboard owner end it early.
macOS provides no consumption acknowledgement for a posted Cmd+V, so an arbitrarily delayed
receiver can still outlast the budget.

Explicit Secure Paste (`⌘\`) emits `secure_paste` events independently of verbose
logging. Each boundary records one outcome: `capture`, explicit field `selection`,
`picker`, `authentication`, `handoff`, `preparation`, `delivery`, and `completion`.
The required fields are `stage`, `outcome`, `target`, `transport`, `reason`, `attempts`
(0–16), and `duration_ms` (0–600,000). Optional `ax_error_code` is a signed 32-bit
numeric AX result; authentication errors include only `error_family` and `error_code`.
Target categories are `unresolved`, `focused`, `descendant`, and `explicit`. Transport
is `none`, `secure_value`, `secure_unicode`, `web_range`, or `unicode`. `secure_unicode`
identifies the browser-password keyboard-input route. These are closed enums, never
application names, AX descriptions, window titles, identifiers, geometry, field
contents, or snippet identities. The export validator also rejects unknown enum
values, invalid bounds, and unpaired error fields. These low-frequency outcomes
remain asynchronous; no per-poll events are written.

Handoff retries are aggregated into one event. Its reason identifies the final
failure or, on recovery, the first transient condition (for example
`keyboard_owner_pending`). The same `secure_paste` / `handoff` boundary now covers
the snippet picker, clipboard history insertion, and authenticated suggestion
expansion. Its complete optional progress group is:

- `handoff_source`: `snippet_picker`, `clipboard_history`, or `secure_expansion`;
- `after_authentication`: whether recovery follows authentication and the Keychain read;
- `focus_confirmations`: consecutive successful observations at completion (0–16,
  never above the required count);
- `required_focus_confirmations`: the required count (1–16);
- `first_wait_reason`: the first transient condition, or `none`, from the existing
  closed reason vocabulary.

Authenticated insertion requires three confirmations, with 25 ms between successful
observations (50 ms total waiting when the destination is immediately ready).
An interruption resets the count. Unauthenticated insertion can proceed on the first
valid observation. A failed event with `focus_confirmations: 2` and
`required_focus_confirmations: 3` shows that recovery ended before stability was
confirmed; it does not claim that text was delivered. Old records without this group
remain exportable; partial groups, unknown strings, extra fields, invalid types,
and out-of-range counts are rejected. No content, names, PIDs, AX descriptions, or
raw errors enter this group, and it adds no synchronous disk writes or per-poll logs.

Stale controls, changed windows/ancestry, a different
concrete focused control, and a changed hit target remain terminal refusals.
`delivery` is emitted only if the delivery function was reached. AX success for a
native password-value write is `ambiguous` with reason `ax_write_unconfirmed`, even
with `ax_error_code: 0`: API acceptance is not delivery proof. Browser-password Unicode
delivery is also `ambiguous`, with `direct_input_unconfirmed`, because keyboard posting
has no host acknowledgement and password values are never read. Normal keyboard dispatch
does not show a warning HUD or beep; this diagnostic uncertainty does not mean a failure
was detected. Its completion reason is also `direct_input_unconfirmed`, and it is not
counted as verified usage. An AX error after a write is `ambiguous`, never
permission to retry with a different transport. `completion` summarizes the overall
attempt; consult the preceding stage for its specific failure reason. Returning
focus after cancellation or failure does not emit a second handoff event.

`pasteboard_recovery` records one aggregate `outcome` (`restored`, `superseded`, or `pending`)
per retry batch after an earlier restoration failure, including failed acquisition rollback.
No per-write or per-poll records are emitted. Normal results are asynchronous; a still-pending
restoration is an error persisted synchronously because the user's snapshot is still owed.
Neither event contains clipboard or snippet text, keywords, names, formats, text fingerprints,
identifiers, paths, or application identity. The fingerprint itself stays only in memory.

Per-keystroke expansion Accessibility diagnostics are opt-in on macOS under
**Settings → Diagnostics → Expansion Accessibility logging**:

- **Off** is the default.
- **This Session** enables collection only until Snippets quits.
- **Always** persists the opt-in across launches.

When enabled, `expansion_accessibility` records only closed operation/outcome values,
the `ax_confirmed` / `local_display_only` / `uncertain_after_host_edit` transition,
the failing AX stage and classified failure when applicable, a numeric AX error code,
and the query length. The closed `local_tracking` outcome identifies a narrowly
authorized session in a text area without a readable insertion caret. It never
records the query, surrounding field text, app identity,
snippet identity, or snippet content. These events are asynchronous debug records; the
setting can be switched off immediately after reproducing a problem to limit volume.

For suggestion dismissal, `missing_trigger` means readable insertion context without
a trigger. A text area's `{0, 0}` range with a non-settable selection and unsupported
caret bounds is instead `unavailable` at `range_text`; it can retain locally tracked
suggestions while the original focus and uninterrupted input session remain valid.
A readable missing trigger never authorizes local deletion, including after secure
authentication. AX timeouts, selections, and inconsistent ranges do not establish
permission for local deletion either.

Use **Settings → Diagnostics → Export Logs** for a single portable JSONL file.
The UI states that the export is plaintext before presenting the save or Files picker.
It can also delete retained logs and a legacy reveal-audit file that could not be
migrated automatically. For engineering collection without opening Settings:

```sh
./scripts/collect-diagnostics.sh --mac
./scripts/collect-diagnostics.sh --ios --device "My iPhone"
```

Pass `--debug` only when collecting the separately installed Debug iOS bundle. The
script never removes the app or its data container and refuses to overwrite an existing
destination.

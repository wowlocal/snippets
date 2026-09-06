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

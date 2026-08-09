# Persistent diagnostics

Snippets writes structured JSON Lines through CocoaLumberjack on macOS and iPadOS.
The app keeps at most 14 days, rolls at 1 MiB or 24 hours, retains at most 64
archives, and caps the log directory at 24 MiB. The diagnostics directory is excluded
from backup; directories use owner-only permissions, files use owner read/write, and
iPad files use complete-until-first-authentication data protection.

Each line is schema version 1 and contains a UTC timestamp, process-session ID,
monotonic elapsed time, sequence, severity, category, event name, and a closed set of
event-specific fields. Export prepends a `diagnostics_manifest` line and validates every
source line. Only a torn final line may be skipped.

On macOS, `cloud_environment` comes from the running signed process's entitlement. The
iOS SDK has no public runtime API for reading that entitlement, so device logs report it
as `unrecognized` (and simulator logs as `absent`) rather than guessing from the source
plist. For an iPad sync-environment investigation, inspect the built app's signed
entitlements as described in `AGENTS.md` or use the validation in `install-ipad.sh`.

The event API cannot accept snippet bodies, display names, tags, paths, record IDs,
ciphertext, keys, arbitrary error descriptions, or `NSError.userInfo`. Errors are reduced
to a known family and numeric code. Secure-snippet keywords are explicitly approved
metadata; they are normalized and bounded to 256 UTF-8 bytes.

Use **Settings → Diagnostics → Export Logs** for a single portable JSONL file.
The UI states that the export is plaintext before presenting the save or Files picker.
It can also delete retained logs and a legacy reveal-audit file that could not be
migrated automatically. For engineering collection without opening Settings:

```sh
./scripts/collect-diagnostics.sh --mac
./scripts/collect-diagnostics.sh --ipad --device "My iPad"
```

Pass `--debug` only when collecting the separately installed Debug iPad bundle. The
script never removes the app or its data container and refuses to overwrite an existing
destination.

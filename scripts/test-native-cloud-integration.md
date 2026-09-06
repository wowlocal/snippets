# Native Cloud integration

`test-native-cloud-integration.py` exchanges encrypted, disposable snippets through
the real native email authentication server using the macOS, iPhone, iPad, and Android
app integration harnesses. The existing `test-cross-platform-sync.sh` remains the
independent OIDC protocol regression suite.

Requirements:

- A disposable Snippets Cloud server running `AUTH_MODE=native`, with its HTTPS origin
  in a private file. Its SMTP delivery must use a local Mailpit instance.
- Xcode with an available iOS simulator runtime, plus a **disposable Android emulator**.
  The Android harness resets that emulator's Snippets installation and device key.
- Fresh Android debug and instrumentation APKs built with Snippets Cloud enabled and
  the same origin. The default artifact paths are under `app/build/outputs/apk/`.
- The development gateway below, behind the HTTPS tunnel. It exposes only the API
  and uses the requested disposable space ID to scope failure injection. It must never
  proxy production traffic.

Start the gateway with a private directory and keep the process alive:

```sh
python3 scripts/test-native-cloud-integration-gateway.py \
  --origin-file build/cloud-test/origin \
  --chaos-file build/cloud-test/native-sync-chaos.json \
  --state-file build/cloud-test/native-sync-chaos-state.json
```

It listens on loopback port 8787 and forwards to the API on port 8087. The ports are
configurable. Mailpit stays on loopback; the gateway does not expose its UI or API.

When running behind cloudflared, configure the API's `AUTH_TRUSTED_PROXY_CIDRS` with
only this gateway's immediate network peer address. The gateway always removes an
incoming `X-Snippets-Client-IP` and sets it from Cloudflare's overwritten
`CF-Connecting-IP` header on its loopback tunnel connection. Direct loopback probes
use their socket peer. It does not trust an `X-Forwarded-For` chain. Missing or invalid
client-IP headers from a configured trusted hop are rejected by native auth routes.
Do not expose this test gateway directly to the internet or repurpose its Cloudflare
trust assumption for a different ingress.

Discover the dedicated emulator with `adb devices`, then run:

```sh
python3 scripts/test-native-cloud-integration.py \
  --include-ipad \
  --android-serial <disposable-emulator-serial> \
  --allow-disposable-android-reset
```

The suite builds its own Apple artifacts with the current origin pinned into the app,
creates its own iPhone/iPad simulators, and removes those simulators on completion.
The Mac test host uses the separate `com.khm.snippets.debug.native-sync` bundle and
stable Apple Development signing, with no iCloud entitlements. This keeps its defaults
and Cloud credentials separate from the installed apps. The explicit integration-host
environment disables automatic host services while the test owns the isolated stack.
`--skip-build` reuses artifacts only when their app metadata contains that exact origin.
`--android-ready-file` can wait for a cooperating test runner to hand over the emulator.
`--apple-ready-file` waits after the Mac seed phase for other iOS test runners to finish.
Only the simulator needed by the current phase is booted; it shuts down after that phase.
See `--help` for custom origin, Mailpit, artifact, and report paths.

The suite verifies email delivery and token rotation, then runs fifteen app phases:
create on Mac/iPhone/Android; edit across platforms; reload and converge; delete with
a lost acknowledgement; recover from a truncated page and invalid cursor; and converge
on the tombstone. It also checks a real server CAS conflict and verifies that the wire
blobs do not contain the known test plaintext. Every Apple phase starts from a fresh
isolated library; the Android harness explicitly reloads its persisted installation.
The shared fixed encryption material is test authority supplied directly to isolated
key stores and never reads or changes the user's library keys.

The account is unique for each run. Cleanup revokes the entire refresh-token family
using the original, already rotated token and confirms that the latest access token is
denied. Fixture files are removed once revocation succeeds. Encrypted synthetic records
remain in the disposable server database. The suite never resets a server or deletes
another account, simulator, or library.

Private artifacts and an aggregate JSON report are retained in the printed temporary
directory (mode 0700). Credential fixtures and reports are mode 0600. Command output
contains phase names and counts only; do not publish the private Xcode result bundles
or instrumentation logs, which can retain test configuration. The final aggregate
report is also copied to `build/cloud-test/native-sync-result.json` by default.

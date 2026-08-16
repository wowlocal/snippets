# Snippets Privacy Policy

Last updated: August 13, 2026

Snippets is designed so the developer does not receive or read your snippet library.

## Data stored on your devices

Your snippet library, settings, secure vault, usage ranking, and diagnostics are stored
locally on your devices. Snippets does not include advertising, tracking, or third-party
analytics SDKs.

Secure snippet bodies are encrypted at rest. Their names, keywords, and tags remain
searchable on the device while the vault is locked. A secure body is revealed, copied,
or edited only after device-owner authentication.

On macOS, Snippets marks the secure editor as protected accessibility content, blocks
ambient text-export features, displays the body through a capture-protected system
layer, and reveals those protected pixels only while the pointer is over the editor.
This reduces accidental accessibility scraping, screen capture, and shoulder-surfing
exposure, but cannot prevent a physical camera from recording a body while it is visible
or protect against sufficiently privileged software. The vault auto-locks after five
minutes without secure-content use, no later than thirty minutes after authentication,
and immediately on system/session lock, sleep, screensaver start, or iOS backgrounding.

## Optional iCloud sync

iCloud sync is off by default. If you enable it, Snippets encrypts the library on your
device before storing records in your private CloudKit database. The synchronization key
is stored through iCloud Keychain. The developer does not operate a synchronization
server and cannot view the contents of your private CloudKit database. Apple's handling
of iCloud data is governed by Apple's privacy policy and your iCloud agreement.

## Optional Snippets Cloud and custom-server sync

Snippets Cloud sync is optional. Before upload, the app encrypts the library on your
device; the sync service receives opaque records and encrypted key envelopes, not
snippet plaintext or library keys. It stores a keyed pseudonymous account identifier,
space membership and bounded routing, quota, cursor, and concurrency metadata needed to
operate synchronization.

Account sign-in runs at the configured OpenID Connect identity provider in the system
browser. Snippets has no account password and does not require an email address. The
sync service validates a provider-signed access token, including recent passkey
assurance for key-granting actions, but does not retain email or profile claims, the raw
provider subject, access token, or authentication-method details. Email is not treated
as identity or multifactor authentication. The identity provider handles passkeys,
Apple or Google sign-in, abuse prevention, and account recovery under that provider's
privacy terms.

Each app keeps only the build-pinned server and selected space coordinates plus a
short-lived access token, refresh token, public client identifier, provider endpoints,
resource identifier, and expiry time in
device-bound secret storage. ID tokens and profile claims are discarded. On Apple
platforms this session is in the device-only Keychain; on Android it is encrypted with a
non-exportable Android Keystore key and excluded from backup and device transfer. Each
installation has a separate refresh credential. During sign-out, a device-only encrypted
journal may temporarily retain the old and rotated access/refresh generations until all
have been revoked. A second journal removes the local library-key copy first and account
credentials last; interrupted cleanup resumes on the next launch.

The library encryption key is created locally. A new device receives it through a
short-lived, one-time encrypted QR pairing approved with device-owner authentication and
a fresh passkey check, or decrypts it with the user's offline recovery kit. Pairing QR
codes contain only server/space coordinates, a nonce, an expiry and the new device's
ephemeral public key—never the library key. The recovery QR and long random code are
secrets that should be stored offline; the service keeps only their encrypted envelope.
If setup is interrupted, the pending kit remains encrypted on the device and every later
on-screen reveal requires Face ID, Touch ID, or the device's equivalent authentication.
If every approved device and the recovery kit are lost, the account can still be
recovered, but the old encrypted library is permanently unrecoverable by the developer,
the identity provider and Snippets Cloud.

A custom-server distribution pins its own server, OAuth resource and domain-verified
callback at build time. Its operator receives the same protocol data and resource-bound
authentication tokens as the hosted service and controls that server's retention and
infrastructure. Review that operator's policy before installing that distribution.

## Diagnostics

Snippets keeps bounded diagnostic logs locally for troubleshooting. It does not send
those logs automatically. You decide whether to export and share them. Exported logs do
not contain snippet bodies, display names, tags, record identifiers, filesystem paths,
ciphertext, or encryption keys. They may contain aggregate operation counts and closed
CloudKit callback and scheduler states. A sanitized secure-snippet keyword may be present.

## Backups, exports, and sharing

Files and links you intentionally export or share are handled by the destination you
choose. Ordinary sharing exports exclude secure snippet bodies. A complete encrypted
backup includes secure snippets and is protected by the password you provide.

## Contact

For privacy questions, support requests, or deletion guidance, open an issue at
<https://github.com/wowlocal/snippets/issues>.

## Changes

This policy may be updated when Snippets changes. The date above identifies the latest
revision.

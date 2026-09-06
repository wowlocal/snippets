# Snippets Privacy Policy

Last updated: September 6, 2026

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

Account sign-in uses native email and one-time-code screens. The app sends the email
address and the code you enter to its build-pinned Snippets Cloud server over HTTPS.
The server stores the verified email and an opaque, immutable account ID. Pending
challenges also contain the delivery address, a keyed code digest, expiry and attempt
state; access and refresh credentials are stored as keyed digests. Abuse controls use
bounded counters keyed from the email address and network address. The operator's
configured email service receives the destination address and sign-in code, and its
retention is governed by that service's policy. Email-code sign-in is not a passkey or
multifactor authentication.

Each app keeps its pinned server and selected library coordinates, verified email,
opaque account ID, short-lived access token, refresh token and expiry time. Account
profile and session secrets stay in device-bound secret storage: the device-only
Keychain on Apple platforms, or storage encrypted with a non-exportable Android
Keystore key and excluded from backup and device transfer on Android. Each installation
has a separate refresh credential. Credential replacement and sign-out can temporarily
retain old and rotated access/refresh generations in encrypted cleanup journals until
the required revocation completes. A separate cleanup journal removes the local
library-key copy before account credentials; interrupted cleanup resumes on launch.
Email addresses, sign-in codes, account IDs and tokens are not included in app diagnostics.

Account access and library decryption are separate. The library encryption key is
created locally. A new device receives it through short-lived, one-time encrypted QR
pairing approved by a device that already has the key, or decrypts it with the user's
offline recovery kit. Pairing approval and recovery replacement require device-owner
authentication and a cryptographic proof made with the existing library key; an email
code alone cannot authorize them. Pairing invitations contain public routing and
handshake material, never the plaintext library key. Recovery QR codes and long random
codes are secrets that should be stored offline; the service keeps their encrypted
envelope. A pending recovery kit stays encrypted on the device, and later on-screen
reveal requires Face ID, Touch ID, or the device's equivalent authentication. If every
approved device and the recovery kit are lost, restoring account access does not restore
the old library encryption key. The service and email provider cannot decrypt that library.

A custom-server distribution pins its own HTTPS origin at build time. Its operator
receives the same account, email-delivery and synchronization data as the hosted service
and controls its infrastructure, email provider and retention. Review that operator's
policy before installing that distribution.

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

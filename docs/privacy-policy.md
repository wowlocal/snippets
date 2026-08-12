# Snippets Privacy Policy

Last updated: August 12, 2026

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

## Diagnostics

Snippets keeps bounded diagnostic logs locally for troubleshooting. It does not send
those logs automatically. You decide whether to export and share them. Exported logs do
not contain snippet bodies, display names, tags, record identifiers, filesystem paths,
ciphertext, or encryption keys. A sanitized secure-snippet keyword may be present.

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

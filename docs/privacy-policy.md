# Snippets Privacy Policy

Last updated: August 9, 2026

Snippets is designed so the developer does not receive or read your snippet library.

## Data stored on your devices

Your snippet library, settings, secure vault, usage ranking, and diagnostics are stored
locally on your devices. Snippets does not include advertising, tracking, or third-party
analytics SDKs.

Secure snippet bodies are encrypted at rest. Their names, keywords, and tags remain
searchable on the device while the vault is locked. A secure body is revealed, copied,
or edited only after device-owner authentication.

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

# ADR 0004: Account login and encrypted library access

- Status: implemented behind the disabled Snippets Cloud feature flag; real provider acceptance pending
- Date: 2026-09-06
- Amends: ADR 0003 for the schema-2 additive rollout before public launch

Account authentication is OIDC code + PKCE in the system browser. Apple, Google and email
OTP identify an account; an optional passkey strengthens its login. Identity remains the
server's issuer/subject digest. Name/email are display data, never key lookup or linking
identifiers. Global Logto Cloud and regional Logto OSS are independent deployments.

Login, library access and recovery setup are separate UI concerns. New libraries can
sync while their recovery kit remains unsaved. The encrypted durable presentation remains
on the device, and Settings reminds the user to save it. Revealing it requires local
user presence each time. A completed-but-unsaved presentation is not a pending upload.
Disconnect retains the remote-revoke-before-local-erase journal and warns about access
loss; deferral alone does not block disconnect. Local snippets remain available.

Protocol 2.1 adds `library-action-proof-v1`. An empty library atomically installs an
Ed25519 public key and the first opaque recovery envelope. It must have no prior authority,
envelope, records or changes. The same quota/space lock used by data writes makes two
initial devices and concurrent record writes serialize. The server never sees a root key.

Clients derive a signing seed via HKDF-SHA256 from the existing 32-byte root and 32-byte
salt. The info is UTF-8 `snippets-library-action-signing-v1\n`, canonical HTTPS API origin,
newline, lowercase server-instance UUID, newline, lowercase space UUID. This derivation
is implemented in shared Swift and exported through JNI to Android. It is separate from
all existing encryption derivations; wire, pairing and recovery envelopes are unchanged.

Before recovery replacement or pairing approval, the native UI requires fresh local
owner authentication. The authenticated client obtains a five-minute challenge for a
specific action hash and epoch. The server stores identity digest, complete scope,
action, epoch, hash and random nonce. Signature input is UTF-8
`snippets-library-action-proof-v1\n` followed by the 32 nonce bytes. The client checks the
returned bindings before signing. The server verifies them again under the mutation lock.

Recovery request hash: SHA256 of newline-joined `snippets-recovery-action-v1`, decimal
key epoch, decimal expected version or `null`, algorithm, canonical standard Base64
ciphertext. Pairing hash: newline-joined `snippets-pairing-action-v1`, lowercase pairing
UUID, Base64 recipient-key hash, algorithm, Base64 ciphertext. No trailing newline.

Verification, mutation and a typed response receipt commit together. Only the original
identity/scope/action/body/signature can replay that receipt before expiry. There are at
most 16 unexpired challenges per library, including receipts. Runtime RLS exposes the
public authority to members and challenge mutation to writers; authority insertion is
owner-only and the runtime cannot update an installed authority. An OAuth token alone
cannot authorize either mutation.

The previous API has never been deployed. There is no legacy strong-auth upgrade or
unsigned mutation route. A library without an authority cannot approve a device or
replace recovery; only an empty library can initialize both atomically. Recovered/paired
keys must match its authority before activation.

Schema migration 2 is additive and retains the existing migration runner and first-boot
workflow. Fresh databases bootstrap version 1
then run the migration runner. Runtime requires version 2; old binaries must not be
rolled back against schema 2 unless their compatibility range was explicitly expanded.
No database reset, account merge, cloud deployment or release is part of this change.

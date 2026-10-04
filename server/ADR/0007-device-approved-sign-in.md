# ADR 0007: Device-approved sign-in

- Status: server implemented; clients implement the contract below
- Date: 2026-10-03
- Amends: ADR 0006

A device that already opens the library can sign a new device in to the same account and
give it the library key in one approval. Nobody types or transfers the account key. The key
remains the fallback when no approved device is at hand.

## Decision

The flow reuses pairing for all key material. The new device opens an unauthenticated
**device request** that holds its pairing recipient key and nonce. The approving device
creates and approves an ordinary pairing for exactly that key and nonce, then binds the
request to its own account. The server binds a request only when the caller can write
the space and holds an **approved** pairing whose recipient key hash and nonce equal the
request's. Approving that pairing already required fresh device-owner authentication and a
library-action proof. A stolen bearer token therefore cannot mint a session for another
device. The account bound is the one that owns the approving access credential; callers
never name an account.

## Protocol

Discovery adds capability `native-device-sign-in-v1`. Endpoints are fixed on the pinned
origin; `nativeAuth` is unchanged.

```text
POST /v2/auth/device-requests                     {"recipientPublicKey","nonce"} → {"requestId","pollToken","expiresAt"}
POST /v2/auth/device-requests/{id}/approval      Bearer; {"spaceId","pairingId"} → 204
POST /v2/auth/device-requests/{id}/claim         {"pollToken"} → {"state":"pending","expiresAt"}
                                                   or {"state":"approved","expiresAt","spaceId","pairingId","session"}
```

- `recipientPublicKey` is the 65-byte uncompressed P-256 point and `nonce` 32 bytes, both
  canonical standard Base64, exactly as in `POST /v2/spaces/{space}/pairings`. The point
  must be on the curve.
- A request lives ten minutes. `pollToken` (`sn_d_` plus 43 Base64url symbols) is
  returned once, is the only claim credential, and is stored server-side as a keyed digest.
- Approval is idempotent for the same account, space and pairing; any other rebinding,
  key or nonce mismatch, or an unapproved pairing is `409 conflict`. An unknown request is
  `404 not_found`; an expired one is `410 pairing_expired`; an invalid credential is
  `401 authentication_required`; a reader is `403 forbidden`.
- An approved claim opens a new session family for the bound account. A repeated claim
  follows a lost response: it revokes the previously issued family before opening a new
  one, at most five claims per request (then `409 conflict`). Unknown request or wrong poll
  token is `404 not_found`; expiry is `410 pairing_expired`.
- Rate limits: request creation 30/source-IP/hour and 3,000/deployment/hour; claims
  1,800/source-IP/hour and 100,000/deployment/hour. Approval uses the authenticated
  principal limits. Create and claim follow the trusted-proxy client-IP rules.

## Client contract

### New device (signed out)

1. The signed-out account screen gains **Sign In with Another Device**.
2. Generate the platform's existing pairing recipient material (P-256 key pair, 32-byte
   nonce) and keep it, with `requestId` and `pollToken`, in the same encrypted device-only
   storage the existing pairing recipient state uses. `pollToken` is a credential: never
   log, export or display it.
3. Show a QR code and copyable text of this payload, encoded with the same rules as the
   existing pairing invitation (sorted keys, no escaped slashes, unpadded Base64url,
   lowercase UUID, canonical HTTPS origin without a trailing slash, at most 4,096 bytes,
   strict exact-key parsing):

   ```json
   {"expiresAt":<epoch seconds>,"kind":"snippets-device-sign-in","nonce":"…","recipientPublicKey":"…","requestId":"…","schemaVersion":1,"server":"https://…"}
   ```

   Also show the existing pairing confirmation code computed from the nonce and recipient
   key. Its derivation is unchanged, so it equals the server's tag for the pairing the
   approver creates.
4. Show the expiry countdown and poll the claim endpoint about every two seconds, honoring
   `Retry-After` and backing off on network failure. **Cancel** discards local state; the
   request simply expires.
5. On `approved`, commit the returned session through exactly the same credential journal
   and commit path as account-key sign-in. The stored session has no account key. Select
   the returned `spaceId` without a chooser, failing closed if it is not in
   `GET /v2/spaces`. Then run the existing recipient pairing claim for the returned
   `pairingId` with the stored recipient material; the existing check that the pairing's
   recipient key and nonce equal the device's own must pass before decryption.
6. On a device signed in this way, **Show Account Key** explains: “This device was signed in
   by another device. View the account key on a device that has it.”

### Approving device

1. The existing add-device entry (scan or paste) accepts `kind:"snippets-device-sign-in"`
   in addition to `snippets-pairing`. The payload's `server` must equal the pinned origin.
2. Before any network call, show the confirmation code and: “Sign in a new device to this
   account? It will also receive this library's key. Continue only if this code matches
   the code on the new device.” Then require the same fresh device-owner authentication as
   pairing approval.
3. `POST /v2/spaces/{space}/pairings` with the payload's key and nonce and
   `expiresInSeconds = clamp(expiresAt − now − 5, 60, 600)`. Require the returned
   `authenticationTag` to equal the confirmation code.
4. Approve that pairing through the existing library-challenge, proof and envelope path.
5. `POST /v2/auth/device-requests/{requestId}/approval` with `{spaceId, pairingId}`. Retry it
   on transport failure; it is idempotent. Show “The new device is signed in.”

Neither device logs the request ID, poll token, payload, confirmation code or any key.
Diagnostics may record closed outcomes for `device_request`, `device_approval` and
`device_claim`.

## Consequences

- Phishing exposure is unchanged: approving a stranger's code already gave away the
  library key, and the confirmation-code check and owner authentication still guard it.
- A device signed in this way cannot reveal the account key. After its 30-day session
  family ends it needs the key or another approval, until ADR 0006's silent
  re-authentication work exists.
- There is no server-side request cancellation; requests expire in ten minutes and are
  pruned an hour later.

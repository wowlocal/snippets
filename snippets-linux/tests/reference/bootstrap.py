"""Development-only OpenSSL interoperability fixture. No real keys or accounts.

Run with Python cryptography; regular Cargo builds/tests read the checked-in JSON
and require neither Python nor OpenSSL. Fixed nonces belong only to this fixture.
"""
import base64
import hashlib
import json
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def b64(value):
    return base64.b64encode(value).decode("ascii")


def url64(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def encoded(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def derive(value, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(value)


def public(private):
    return private.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )


alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
server = "https://sync.example"
space = "01234567-89ab-cdef-0123-456789abcdef"
pairing = "30000000-0000-0000-0000-000000000001"
material = bytes(range(64))
bundle = encoded({"schemaVersion": 1, "scopeID": "sync-v1", "key": b64(material[:32]), "salt": b64(material[32:])})
recipient_bytes = bytes(range(17, 49))
sender_bytes = bytes(range(65, 97))
recipient = ec.derive_private_key(int.from_bytes(recipient_bytes, "big"), ec.SECP256R1())
sender = ec.derive_private_key(int.from_bytes(sender_bytes, "big"), ec.SECP256R1())
pair_nonce = bytes(range(128, 160))
aes_nonce = bytes(range(192, 204))
invitation = {
    "schemaVersion": 2, "kind": "snippets-pairing", "server": server,
    "spaceId": space, "pairingId": pairing, "nonce": url64(pair_nonce),
    "recipientPublicKey": url64(public(recipient)), "expiresAt": 1700000300,
}
pair_aad = "\0".join(["snippets-pairing-v2", server, space, pairing, url64(pair_nonce), url64(public(recipient))]).encode()
shared = sender.exchange(ec.ECDH(), recipient.public_key())
sealed = AESGCM(derive(shared, pair_nonce, pair_aad)).encrypt(aes_nonce, bundle, pair_aad)
envelope = encoded({"schemaVersion": 1, "senderPublicKey": url64(public(sender)), "nonce": url64(aes_nonce), "sealed": url64(sealed)})
confirm = "".join(alphabet[byte & 31] for byte in hashlib.sha256(b"snippets-pairing-confirm-v1" + pair_nonce + public(recipient)).digest()[:8])

secret = bytes(range(160, 192))
recovery_nonce = bytes(range(224, 236))
recovery_aad = "\0".join(["snippets-recovery-v1", server, space, "7"]).encode()
recovery_cipher = recovery_nonce + AESGCM(derive(secret, b"snippets-recovery-salt-v1", recovery_aad)).encrypt(recovery_nonce, bundle, recovery_aad)
# Existing Apple/Android fixture, generated independently from the Rust port.
assert b64(recovery_cipher) == "4OHi4+Tl5ufo6errM76BnjJgguPvUmhNd5AgnCU/ER/39RuP1lz7aQdmGbMn6cg9UVPGUWIVUXzZEEvueXiuszpMILWrVMGyOTHKM1xJMdbfIbuiaYnIU1y9WFVuZXzja72yY7PtDhh1hzCl4wnwNSAViH5YH/x582U8C8eLuw5o9ykjjonPqIrZH8/fOsAgq4NCirT5lxn4PdAsZvNMgCIb9g6ZygGGsKp70/YP"
standard_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
ungrouped = base64.b32encode(secret).decode().rstrip("=").translate(str.maketrans(standard_alphabet, alphabet))
code = "-".join(ungrouped[index:index + 4] for index in range(0, len(ungrouped), 4))
recovery_qr = encoded({"schemaVersion": 1, "kind": "snippets-recovery", "server": server, "spaceId": space, "keyEpoch": 7, "secret": url64(secret)})

instance = "10000000-0000-0000-0000-000000000001"
authority_space = "20000000-0000-0000-0000-000000000001"
authority_info = f"snippets-library-action-signing-v1\n{server}\n{instance}\n{authority_space}".encode()
authority = ed25519.Ed25519PrivateKey.from_private_bytes(derive(material[:32], material[32:], authority_info))
authority_public = authority.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
message = b"snippets-library-action-proof-v1\n" + bytes([7] * 32)
signature = authority.sign(message)
assert b64(authority_public) == "BpJCgx4cUQSQFyZtp9NGBSH/vu8g+LUff0Gzc60K4kc="
assert b64(signature) == "SpmC5BUDjmvaeUhXOjcTs6NtUfD+ncwuUbzstz3x7AqqSNwKasvgalPp0F0Ly8JKPW+qqzodsPyV8VuMniznCw=="
recovery_hash = lambda version: hashlib.sha256("\n".join(["snippets-recovery-action-v1", "7", version, "snippets-recovery-hkdf-sha256-aes256gcm-v1", b64(recovery_cipher)]).encode()).digest()
pair_hash = hashlib.sha256("\n".join(["snippets-pairing-action-v1", pairing, b64(hashlib.sha256(public(recipient)).digest()), "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1", b64(envelope)]).encode()).digest()
fixture = {
    "material": b64(material), "bundleJSON": bundle.decode(),
    "pairing": {"recipientPrivate": b64(recipient_bytes), "senderPrivate": b64(sender_bytes), "invitationJSON": encoded(invitation).decode(), "nonce": b64(aes_nonce), "envelopeJSON": envelope.decode(), "confirmationCode": confirm, "requestHash": b64(pair_hash)},
    "recovery": {"qrJSON": recovery_qr.decode(), "code": code, "nonce": b64(recovery_nonce), "ciphertext": b64(recovery_cipher), "createHash": b64(recovery_hash("null")), "replaceHash": b64(recovery_hash("1"))},
    "authority": {"serverInstanceId": instance, "spaceId": authority_space, "publicKey": b64(authority_public), "signature": b64(signature)},
}
output = Path(__file__).resolve().parent.parent / "fixtures" / "bootstrap-v1.json"
output.write_text(json.dumps(fixture, indent=2) + "\n")

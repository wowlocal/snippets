"""Development-only portable-backup reference using stdlib and OpenSSL EVP.

All material is public fiction. Cargo consumes checked-in bytes and needs no
Python/OpenSSL runtime. No Rust serializer or cryptographic helper is called.
"""
import argparse
import base64
import ctypes as c
import ctypes.util
import hashlib
import hmac
import json
import struct
import unicodedata
import uuid
from pathlib import Path

FORMAT = "com.khm.snippets.encrypted-backup"
PASSWORD = "Café public backup fixture"
LIB = c.CDLL(ctypes.util.find_library("crypto"))
for name, result, args in [
    ("EVP_CIPHER_CTX_new", c.c_void_p, []),
    ("EVP_CIPHER_CTX_free", None, [c.c_void_p]),
    ("EVP_aes_256_gcm", c.c_void_p, []),
    ("EVP_CIPHER_CTX_ctrl", c.c_int, [c.c_void_p, c.c_int, c.c_int, c.c_void_p]),
]:
    function = getattr(LIB, name)
    function.restype, function.argtypes = result, args
for mode in ["Encrypt", "Decrypt"]:
    for suffix, args in [
        ("Init_ex", [c.c_void_p, c.c_void_p, c.c_void_p, c.c_char_p, c.c_char_p]),
        ("Update", [c.c_void_p, c.c_void_p, c.POINTER(c.c_int), c.c_char_p, c.c_int]),
        ("Final_ex", [c.c_void_p, c.c_void_p, c.POINTER(c.c_int)]),
    ]:
        function = getattr(LIB, f"EVP_{mode}{suffix}")
        function.restype, function.argtypes = c.c_int, args


def aes(key, nonce, data, aad, decrypt=False):
    assert len(key) == 32 and len(nonce) == 12
    context = LIB.EVP_CIPHER_CTX_new()
    assert context
    mode = "Decrypt" if decrypt else "Encrypt"
    init = getattr(LIB, f"EVP_{mode}Init_ex")
    update = getattr(LIB, f"EVP_{mode}Update")
    final = getattr(LIB, f"EVP_{mode}Final_ex")
    length = c.c_int()
    try:
        assert init(context, LIB.EVP_aes_256_gcm(), None, key, nonce) == 1
        assert update(context, None, c.byref(length), aad, len(aad)) == 1
        tag = c.create_string_buffer(data[-16:] if decrypt else 16)
        message = data[:-16] if decrypt else data
        output = c.create_string_buffer(len(message) + 16)
        assert update(context, output, c.byref(length), message, len(message)) == 1
        written = length.value
        if decrypt:
            assert LIB.EVP_CIPHER_CTX_ctrl(context, 0x11, 16, tag) == 1
        assert final(context, c.byref(output, written), c.byref(length)) == 1
        result = output.raw[:written + length.value]
        if not decrypt:
            assert LIB.EVP_CIPHER_CTX_ctrl(context, 0x10, 16, tag) == 1
            result += tag.raw[:16]
        return result
    finally:
        LIB.EVP_CIPHER_CTX_free(context)


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def un64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def domain(name, fields):
    return b"".join(struct.pack(">I", len(v)) + v for v in [name.encode(), *fields])


def hkdf(key, salt, info):
    extracted = hmac.digest(salt, key, "sha256")
    return hmac.digest(extracted, info + b"\x01", "sha256")


def seal(data, key, aad, nonce):
    padded = data + b"\x80"
    padded += bytes(-len(padded) % 256)
    return "v1." + b64(nonce) + "." + b64(aes(key, nonce, padded, aad))


def opened(text, key, aad):
    version, nonce, cipher = text.split(".")
    assert version == "v1"
    padded = aes(key, un64(nonce), un64(cipher), aad, decrypt=True).rstrip(b"\0")
    assert padded[-1:] == b"\x80"
    return padded[:-1]


def pass_key(password, salt, rounds):
    return hashlib.pbkdf2_hmac("sha512", unicodedata.normalize("NFC", password).encode(), salt, rounds, 32)


def pass_aad(wrapped, backup_id):
    return domain("snip.kdf.v1", [wrapped["alg"].encode(), struct.pack(">Q", wrapped["iterations"]), un64(wrapped["salt"]), backup_id.encode()])


def payload_aad(container):
    wrap = container["wrappedKey"]
    return domain("snip.backup.payload.v1", [FORMAT.encode(), struct.pack(">Q", container["schemaVersion"]), container["backupID"].encode(), wrap["alg"].encode(), struct.pack(">Q", wrap["iterations"]), wrap["salt"].encode(), wrap["envelope"].encode()])


def vault_aad(backup_id, kid):
    return domain("snip.backup.vault-key-aad.v1", [b"v1", backup_id.encode(), kid.encode()])


def vault_wrap_key(key, vault, backup_id):
    return hkdf(key, un64(vault["vaultSalt"]), b"snip.backup.vault-key.v1|" + backup_id.encode() + b"\0" + vault["kid"].encode())


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def read_backup(container):
    wrap = container["wrappedKey"]
    key = opened(wrap["envelope"], pass_key(PASSWORD, un64(wrap["salt"]), wrap["iterations"]), pass_aad(wrap, container["backupID"]))
    payload = json.loads(opened(container["payload"], key, payload_aad(container)))
    if payload.get("vault"):
        vault = payload["vault"]
        root = opened(payload["wrappedVaultKey"], vault_wrap_key(key, vault, container["backupID"]), vault_aad(container["backupID"], vault["kid"]))
        assert root == bytes([0x11]) * 32
        salt = un64(vault["vaultSalt"])
        for record in vault["records"]:
            identifier = uuid.UUID(record["id"]).bytes
            record_key = hkdf(root, salt, b"snip.wire.v1|" + identifier)
            body = opened(record["sealed"], record_key, domain("snip.aad.v1", [b"v1", vault["kid"].encode(), identifier, b"\0"]))
            assert hmac.digest(hkdf(root, salt, b"snip.chash.v1"), body, "sha256")[:16].hex() == record["contentHash"]
    return payload


def generate():
    directory = Path(__file__).resolve().parent.parent / "fixtures"
    vault_fixture = json.loads((directory / "crypto-v1.json").read_text())
    vault = vault_fixture["document"]
    vault["futurePublicBackupField"] = {"enabled": True}
    vault["local.syncConflictC0Receipts.v1"] = {"public-device-receipt": "public-opaque-receipt"}
    identifier = "b-public-backup-interop-v1"
    key = bytes([0x88]) * 32
    root = bytes([0x11]) * 32
    wrap = {"alg": "pbkdf2-hmac-sha512", "iterations": 600000, "salt": b64(bytes([0x99]) * 16)}
    wrap["envelope"] = seal(key, pass_key(PASSWORD, un64(wrap["salt"]), wrap["iterations"]), pass_aad(wrap, identifier), bytes([0xAA]) * 12)
    plain = {"id": "00000000-0000-4000-8000-000000000002", "name": "Public backup name", "keyword": "public-backup", "content": "Public ordinary backup body 🦀", "tags": ["Public"], "isEnabled": True, "isPinned": True, "createdAt": 123.25, "updatedAt": 456.5}
    payload = {"schemaVersion": 1, "snippets": [plain], "vault": vault, "wrappedVaultKey": seal(root, vault_wrap_key(key, vault, identifier), vault_aad(identifier, vault["kid"]), bytes([0xBB]) * 12)}
    container = {"format": FORMAT, "schemaVersion": 1, "backupID": identifier, "wrappedKey": wrap}
    container["payload"] = seal(encode(payload), key, payload_aad(container), bytes([0xCC]) * 12)
    assert read_backup(container) == payload
    result = {"comment": "Public fictional OpenSSL EVP reference; fixed nonces are never used by the app.", "password": PASSWORD, "container": container, "ordinary": plain}
    (directory / "backup-v1.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path)
    arguments = parser.parse_args()
    if arguments.verify:
        container = json.loads(arguments.verify.read_text())
        assert container["wrappedKey"]["iterations"] == 600000
        payload = read_backup(container)
        assert all(not k.startswith("local.syncConflictC0Receipts.") for k in payload["vault"])
        assert payload["vault"]["futurePublicBackupField"] == {"enabled": True}
        print("OpenSSL authenticated the Rust backup, vault key, record bodies and hashes.")
    else:
        generate()

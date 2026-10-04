"""Independent OpenSSL check of a real CLI-created public fictional vault record."""
import hmac
import json
import sys
import uuid
from pathlib import Path
from backup import domain, hkdf, opened, un64, pass_key, pass_aad

assert len(sys.argv) in (3, 4)
editor = len(sys.argv) == 4 and sys.argv[3] == 'editor'
assert len(sys.argv) == 3 or editor
vault = json.loads(Path(sys.argv[1]).read_text())
expected = Path(sys.argv[2]).read_bytes()
keyword = 'public-editor-created' if editor else 'public-cli-created'
records = [record for record in vault['records'] if record['keyword'] == keyword]
assert len(records) == 1
record = records[0]
root = bytes([0x11]) * 32
salt = un64(vault['vaultSalt'])
identifier = uuid.UUID(record['id']).bytes
body = opened(record['sealed'], hkdf(root, salt, b'snip.wire.v1|' + identifier),
              domain('snip.aad.v1', [b'v1', vault['kid'].encode(), identifier, b'\0']))
print('native_body_bytes_match=' + str(body == expected).lower(), flush=True)
assert body == expected
assert hmac.digest(hkdf(root, salt, b'snip.chash.v1'), body, 'sha256')[:16].hex() == record['contentHash']
if editor:
    password = sys.stdin.read()
    if password:
        kdf = vault['kdf']
        # Vault KDF names this field saltP; portable-backup KDF names it salt.
        wrapped = opened(vault['wrapPass'], pass_key(password, un64(kdf['saltP']), kdf['iterations']),
                         pass_aad({**kdf, 'salt': kdf['saltP']}, vault['kid']))
        print('native_passphrase_wrap_matches=' + str(wrapped == root).lower(), flush=True)
        assert wrapped == root
print('OpenSSL authenticated the actual native-created public record and content hash.')

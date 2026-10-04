"""Independent OpenSSL check of a real CLI-created public fictional vault record."""
import hmac
import json
import sys
import uuid
from pathlib import Path
from backup import domain, hkdf, opened, un64

assert len(sys.argv) == 3
vault = json.loads(Path(sys.argv[1]).read_text())
expected = Path(sys.argv[2]).read_bytes()
records = [record for record in vault['records'] if record['keyword'] == 'public-cli-created']
assert len(records) == 1
record = records[0]
root = bytes([0x11]) * 32
salt = un64(vault['vaultSalt'])
identifier = uuid.UUID(record['id']).bytes
body = opened(record['sealed'], hkdf(root, salt, b'snip.wire.v1|' + identifier),
              domain('snip.aad.v1', [b'v1', vault['kid'].encode(), identifier, b'\0']))
assert body == expected
assert hmac.digest(hkdf(root, salt, b'snip.chash.v1'), body, 'sha256')[:16].hex() == record['contentHash']
print('OpenSSL authenticated the actual CLI-created public record and content hash.')

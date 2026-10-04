"""Independent OpenSSL validation of an actual private-fixture native setup.

Credentials arrive only on stdin; no key, body or reflected error is printed.
"""
import hmac
import json
import sys
import uuid
from pathlib import Path
from backup import domain, hkdf, opened, un64, pass_key, pass_aad


def verify():
    request = json.load(sys.stdin)
    vault = json.loads(Path(sys.argv[1]).read_text())
    kdf = vault['kdf']
    assert kdf['alg'] == 'pbkdf2-hmac-sha512' and kdf['iterations'] == 600000
    root = opened(vault['wrapPass'],
                  pass_key(request['passphrase'], un64(kdf['saltP']), kdf['iterations']),
                  pass_aad({**kdf, 'salt': kdf['saltP']}, vault['kid']))
    assert len(root) == 32
    alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    text = ''.join(c.upper() for c in request['recovery'] if not c.isspace() and c not in '-_')
    symbols = [alphabet.index(c.replace('I', '1').replace('L', '1').replace('O', '0')) for c in text]
    assert len(symbols) == 27
    assert sum((2 * i + 1) * v for i, v in enumerate(symbols[:-1])) % 32 == symbols[-1]
    bits = 0
    for value in symbols[:-1]:
        bits = (bits << 5) | value
    assert bits & 3 == 0
    material = (bits >> 2).to_bytes(16, 'big')
    salt = un64(vault['vaultSalt'])
    recovery_root = opened(vault['wrapRecovery'], hkdf(material, salt, b'snip.wrap.v1|recovery'),
                           domain('snip.wrap.v1', [b'v1', b'recovery', vault['kid'].encode()]))
    assert root == recovery_root
    records = vault['records']
    if request['body'] is None:
        assert records == []
    else:
        assert len(records) == 1 and records[0]['keyword'] == 'public-setup-created'
        record = records[0]
        identifier = uuid.UUID(record['id']).bytes
        body = opened(record['sealed'], hkdf(root, salt, b'snip.wire.v1|' + identifier),
                      domain('snip.aad.v1', [b'v1', vault['kid'].encode(), identifier, b'\0']))
        assert body == request['body'].encode()
        assert hmac.digest(hkdf(root, salt, b'snip.chash.v1'), body, 'sha256')[:16].hex() == record['contentHash']


try:
    verify()
except Exception:
    print('Independent native setup authentication failed.')
    sys.exit(1)
print('OpenSSL authenticated the native setup passphrase, displayed recovery key and encrypted records.')

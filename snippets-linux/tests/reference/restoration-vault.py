"""Public second-vault fixture and independent native-restoration verifier.

Development/acceptance only: stdlib + OpenSSL EVP, never a Rust helper.
Cargo consumes checked-in JSON; no Python is required by either desktop app.
"""
import argparse
import copy
import hmac
import json
import uuid
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from backup import b64, domain, hkdf, opened, pass_aad, pass_key, seal, un64

FIXTURES = Path(__file__).resolve().parent.parent / 'fixtures'
ROOT = bytes([0x44]) * 32
MATERIAL = bytes([0x99]) * 16
PASSWORD = 'Café public current vault fixture'
BODY = 'Public independently protected current vault seed'


def root_from_wraps(doc):
    kdf = doc['kdf']
    assert kdf['iterations'] == 600000 and kdf['alg'] == 'pbkdf2-hmac-sha512'
    root = opened(doc['wrapPass'], pass_key(PASSWORD, un64(kdf['saltP']), kdf['iterations']),
                  pass_aad({**kdf, 'salt': kdf['saltP']}, doc['kid']))
    assert root == ROOT
    recovered = opened(doc['wrapRecovery'], hkdf(MATERIAL, un64(doc['vaultSalt']), b'snip.wrap.v1|recovery'),
                       domain('snip.wrap.v1', [b'v1', b'recovery', doc['kid'].encode()]))
    assert recovered == ROOT
    return root


def record_body(doc, record, root):
    salt = un64(doc['vaultSalt'])
    identifier = uuid.UUID(record['id']).bytes
    body = opened(record['sealed'], hkdf(root, salt, b'snip.wire.v1|' + identifier),
                  domain('snip.aad.v1', [b'v1', doc['kid'].encode(), identifier, b'\0']))
    assert hmac.digest(hkdf(root, salt, b'snip.chash.v1'), body, 'sha256')[:16].hex() == record['contentHash']
    return body


def generated():
    source = json.loads((FIXTURES / 'crypto-v1.json').read_text())
    doc = copy.deepcopy(source['document'])
    doc['kid'] = 'public-independent-current-vault'
    doc['vaultSalt'] = b64(bytes([0x55]) * 32)
    kdf = {'alg': 'pbkdf2-hmac-sha512', 'iterations': 600000, 'saltP': b64(bytes([0x88]) * 16)}
    doc['kdf'] = kdf
    doc['wrapPass'] = seal(ROOT, pass_key(PASSWORD, un64(kdf['saltP']), kdf['iterations']),
                           pass_aad({**kdf, 'salt': kdf['saltP']}, doc['kid']), bytes([0xAA]) * 12)
    doc['wrapRecovery'] = seal(ROOT, hkdf(MATERIAL, un64(doc['vaultSalt']), b'snip.wrap.v1|recovery'),
                               domain('snip.wrap.v1', [b'v1', b'recovery', doc['kid'].encode()]), bytes([0xBB]) * 12)
    doc['futurePublicCurrentVaultField'] = {'enabled': True}
    record = doc['records'][0]
    record['name'] = 'Public independently protected current seed'
    record['keyword'] = 'public-current-seed'
    record['tags'] = ['public-current-seed-tag']
    identifier = uuid.UUID(record['id']).bytes
    salt = un64(doc['vaultSalt'])
    record['sealed'] = seal(BODY.encode(), hkdf(ROOT, salt, b'snip.wire.v1|' + identifier),
                            domain('snip.aad.v1', [b'v1', doc['kid'].encode(), identifier, b'\0']), bytes([0xCC]) * 12)
    record['contentHash'] = hmac.digest(hkdf(ROOT, salt, b'snip.chash.v1'), BODY.encode(), 'sha256')[:16].hex()
    assert root_from_wraps(doc) == ROOT and record_body(doc, record, ROOT) == BODY.encode()
    return {'comment': 'Public fictional independent OpenSSL EVP fixture. Fixed keys/nonces are never used by the application.',
            'rootKeyHex': ROOT.hex(), 'recoveryMaterialHex': MATERIAL.hex(), 'passphrase': PASSWORD,
            'plaintext': BODY, 'document': doc}


def verify_native(path):
    fixture = json.loads((FIXTURES / 'restoration-current-vault-v1.json').read_text())
    doc = json.loads(path.read_text())
    header = {k: v for k, v in doc.items() if k != 'records'}
    assert header == {k: v for k, v in fixture['document'].items() if k != 'records'}
    root = root_from_wraps(doc)
    source = json.loads((FIXTURES / 'crypto-v1.json').read_text())
    restored = next(r for r in doc['records'] if r['id'].lower() == source['document']['records'][0]['id'].lower())
    assert record_body(doc, restored, root) == source['plaintext'].encode()
    extras = [r for r in doc['records'] if r is not restored]
    assert len(extras) == 2
    bodies = {record_body(doc, r, root) for r in extras}
    assert bodies == {b'Public newer secure restoration body after review', b'Public unrelated secure retained body'}
    for r in extras:
        if record_body(doc, r, root) == b'Public newer secure restoration body after review':
            assert not r['isEnabled'] and not r['isPinned'] and r['keyword'] == ''
    # Wrong old scope/key cannot open a re-encrypted protected record.
    try:
        record_body(source['document'], restored, bytes([0x11]) * 32)
    except AssertionError:
        pass
    else:
        raise AssertionError('old vault scope opened a current-vault record')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.verify:
        try:
            verify_native(args.verify)
        except Exception:
            print('Independent native foreign-vault restoration authentication failed.')
            raise SystemExit(1)
        print('OpenSSL authenticated current wraps, re-encrypted saved body, preserved version, unrelated body and old-vault refusal.')
    else:
        data = json.dumps(generated(), ensure_ascii=False, indent=2) + '\n'
        target = FIXTURES / 'restoration-current-vault-v1.json'
        if args.check:
            assert target.read_text() == data
            print('Independent second-vault fixture matches OpenSSL generation.')
        else:
            target.write_text(data)
            print('Generated public independent second-vault fixture.')

"""Public mixed-vault source and independent OpenSSL restoration verifier."""
import argparse
import copy
import hmac
import importlib.util
import json
import sys
import uuid
from pathlib import Path
sys.dont_write_bytecode = True
from backup import (b64, domain, encode, hkdf, opened, pass_aad, pass_key,
                    payload_aad, seal, un64, vault_aad, vault_wrap_key, FORMAT)

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent / 'fixtures'
spec = importlib.util.spec_from_file_location('public_current_vault', HERE / 'restoration-vault.py')
current = importlib.util.module_from_spec(spec)
spec.loader.exec_module(current)
ROOT = bytes([0x77]) * 32
MATERIAL = bytes([0xC3]) * 16
PASSWORD = 'Café public additional vault fixture'
BACKUP_PASSWORD = 'Café public additional backup fixture'
BODY = b'Public additional saved secure body'
SOURCE_ONLY = b'Public source-only secure body which must not be imported'
ADDITIONAL_ID = str(uuid.UUID(int=9002))


def generated():
    doc = copy.deepcopy(json.loads((FIXTURES / 'crypto-v1.json').read_text())['document'])
    doc['vaultSalt'] = b64(bytes([0x88]) * 32)
    kdf = {'alg': 'pbkdf2-hmac-sha512', 'iterations': 600000, 'saltP': b64(bytes([0xD0]) * 16)}
    doc['kdf'] = kdf
    doc['wrapPass'] = seal(ROOT, pass_key(PASSWORD, un64(kdf['saltP']), kdf['iterations']),
                           pass_aad({**kdf, 'salt': kdf['saltP']}, doc['kid']), bytes([0xD1]) * 12)
    doc['wrapRecovery'] = seal(ROOT, hkdf(MATERIAL, un64(doc['vaultSalt']), b'snip.wrap.v1|recovery'),
                               domain('snip.wrap.v1', [b'v1', b'recovery', doc['kid'].encode()]), bytes([0xD2]) * 12)
    template = doc['records'][0]
    records = []
    for value, name, body, nonce in [(9002, 'Public additional saved secure record', BODY, 0xD3),
                                     (9001, 'Public source-only secure record', SOURCE_ONLY, 0xD4)]:
        record = copy.deepcopy(template)
        record['id'] = str(uuid.UUID(int=value))
        record['name'] = name
        record['keyword'] = 'public-additional-' + str(value)
        record['tags'] = ['public-additional-source']
        identifier = uuid.UUID(record['id']).bytes
        record['sealed'] = seal(body, hkdf(ROOT, un64(doc['vaultSalt']), b'snip.wire.v1|' + identifier),
                                domain('snip.aad.v1', [b'v1', doc['kid'].encode(), identifier, b'\0']), bytes([nonce]) * 12)
        record['contentHash'] = hmac.digest(hkdf(ROOT, un64(doc['vaultSalt']), b'snip.chash.v1'), body, 'sha256')[:16].hex()
        records.append(record)
    doc['records'] = records
    doc['futurePublicAdditionalVaultField'] = {'enabled': True}
    backup_id = 'b-public-additional-vault-v1'
    backup_key = bytes([0x15]) * 32
    wrap = {'alg': 'pbkdf2-hmac-sha512', 'iterations': 600000, 'salt': b64(bytes([0x16]) * 16)}
    wrap['envelope'] = seal(backup_key, pass_key(BACKUP_PASSWORD, un64(wrap['salt']), wrap['iterations']),
                            pass_aad(wrap, backup_id), bytes([0x17]) * 12)
    plain = copy.deepcopy(json.loads((FIXTURES / 'backup-v1.json').read_text())['ordinary'])
    plain['id'] = str(uuid.UUID(int=9003))
    plain['content'] = 'Public source-only ordinary body which must not be imported'
    payload = {'schemaVersion': 1, 'snippets': [plain], 'vault': doc,
               'wrappedVaultKey': seal(ROOT, vault_wrap_key(backup_key, doc, backup_id),
                                       vault_aad(backup_id, doc['kid']), bytes([0x18]) * 12)}
    container = {'format': FORMAT, 'schemaVersion': 1, 'backupID': backup_id, 'wrappedKey': wrap}
    container['payload'] = seal(encode(payload), backup_key, payload_aad(container), bytes([0x19]) * 12)
    result = {'comment': 'Public fictional independent OpenSSL fixtures. Same KID as source A, different salt/root. Fixed keys/nonces never enter production.',
              'rootKeyHex': ROOT.hex(), 'recoveryMaterialHex': MATERIAL.hex(), 'passphrase': PASSWORD,
              'backupPassword': BACKUP_PASSWORD, 'plaintext': BODY.decode(), 'document': doc, 'container': container}
    verify_source(result)
    return result


def verify_source(fixture):
    doc = fixture['document']; kdf = doc['kdf']
    assert kdf['iterations'] == 600000
    root = opened(doc['wrapPass'], pass_key(PASSWORD, un64(kdf['saltP']), kdf['iterations']),
                  pass_aad({**kdf, 'salt': kdf['saltP']}, doc['kid']))
    assert root == ROOT
    assert opened(doc['wrapRecovery'], hkdf(MATERIAL, un64(doc['vaultSalt']), b'snip.wrap.v1|recovery'),
                  domain('snip.wrap.v1', [b'v1', b'recovery', doc['kid'].encode()])) == ROOT
    assert [current.record_body(doc, r, root) for r in doc['records']] == [BODY, SOURCE_ONLY]
    a = json.loads((FIXTURES / 'crypto-v1.json').read_text())['document']
    assert a['kid'] == doc['kid'] and a['vaultSalt'] != doc['vaultSalt']
    wrapped = fixture['container']['wrappedKey']; identifier = fixture['container']['backupID']
    key = opened(wrapped['envelope'], pass_key(BACKUP_PASSWORD, un64(wrapped['salt']), wrapped['iterations']), pass_aad(wrapped, identifier))
    payload = json.loads(opened(fixture['container']['payload'], key, payload_aad(fixture['container'])))
    assert payload['vault'] == doc and len(payload['snippets']) == 1
    assert opened(payload['wrappedVaultKey'], vault_wrap_key(key, doc, identifier), vault_aad(identifier, doc['kid'])) == ROOT


def verify_native(path):
    doc = json.loads(path.read_text())
    seed = json.loads((FIXTURES / 'restoration-current-vault-v1.json').read_text())['document']
    assert {k:v for k,v in doc.items() if k != 'records'} == {k:v for k,v in seed.items() if k != 'records'}
    root = current.root_from_wraps(doc)
    a = json.loads((FIXTURES / 'crypto-v1.json').read_text())
    c = json.loads((FIXTURES / 'restoration-additional-vault-v1.json').read_text())
    verify_source(c)
    originals = {a['document']['records'][0]['id'].lower(): a['plaintext'].encode(), ADDITIONAL_ID: BODY}
    bodies = {}
    for record in doc['records']:
        identifier = record['id'].lower(); body = current.record_body(doc, record, root)
        assert identifier not in bodies
        bodies[identifier] = body
        if identifier in originals:
            assert body == originals[identifier]
        elif body in [b'Public newer secure restoration body after review', b'Public newer additional secure body after review']:
            assert not record['isEnabled'] and not record['isPinned'] and record['keyword'] == ''
    assert len(bodies) == 5 and set(bodies.values()) == set(originals.values()) | {
        b'Public newer secure restoration body after review', b'Public newer additional secure body after review', b'Public unrelated mixed secure retained body'}
    assert str(uuid.UUID(int=9001)) not in bodies
    for old, old_root, identifier in [(a['document'], bytes([0x11]) * 32, a['document']['records'][0]['id']), (c['document'], ROOT, ADDITIONAL_ID)]:
        restored = next(r for r in doc['records'] if r['id'].lower() == identifier.lower())
        try:
            current.record_body(old, restored, old_root)
        except AssertionError:
            pass
        else:
            raise AssertionError('old source opened a current-vault record')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        try:
            verify_native(args.verify)
        except Exception:
            print('Independent mixed-vault restoration authentication failed.')
            raise SystemExit(1)
        print('OpenSSL authenticated both mixed sources, independent current wraps, both restored bodies, both disabled preserved versions, unrelated body and old-source refusal.')
    else:
        data = json.dumps(generated(), ensure_ascii=False, indent=2) + '\n'
        path = FIXTURES / 'restoration-additional-vault-v1.json'
        if args.check:
            assert path.read_text() == data
        else:
            path.write_text(data)

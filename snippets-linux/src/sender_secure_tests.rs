//! Saved strict-CAS conflicts resume with a borrowed public-fixture vault key.
use super::*;
use crate::{materializer::Keyring, vault::Document};

#[test]
fn authenticated_send_preserves_secure_loser_before_replacing_the_saved_cas_winner() {
    let temporary = tempfile::tempdir().unwrap();
    let library = Library::open(temporary.path().into()).unwrap();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
    fs::create_dir(temporary.path().join("Vault")).unwrap();
    model::atomic_write(
        &temporary.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let local = crate::projection::current(
        &[],
        Some(&document),
        "11111111",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )
    .unwrap()
    .into_values()
    .next()
    .unwrap();
    let mut winner = envelope(1, "Public authoritative ordinary winner", 0xffff_0000_0000);
    winner.id = local.id;
    let mut server = Server::new();
    let authoritative_version = server.put(WireRecord::seal(&winner, &key(), &SALT).unwrap());
    let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::VaultLocked
    );
    assert_eq!(server.submitted.len(), 1);
    let offered = server.submitted[0][0].clone();
    assert!(offered.expected_record_version.is_none());
    assert!(
        offered
            .record
            .open(&key(), &SALT)
            .unwrap()
            .encode()
            .unwrap()
            == local.encode().unwrap()
    );
    assert_eq!(
        fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
        before
    );
    assert!(
        load(&library)
            .journal
            .outbound
            .as_ref()
            .unwrap()
            .receipts
            .is_some()
    );

    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &document).unwrap();
    let wire_key = key();
    let binding = scope();
    let mut sender = owner(&library, &wire_key, &binding, &|| Ok(()));
    sender.vault_keys = Some(&keys);
    // Consuming an already saved receipt materializes C0 but sends no new batch.
    let progress = sender.send(&mut server, 1).unwrap();
    assert_eq!(progress.status, Status::MoreBatches);
    assert_eq!(progress.conflicts, 1);
    assert_eq!(server.submitted.len(), 1);
    let saved = crate::vault::read_document(temporary.path())
        .unwrap()
        .unwrap();
    assert_eq!(saved.records.len(), 1);
    let copy = &saved.records[0];
    let copy_id = copy.metadata.id;
    let seal = copy.sealed.clone();
    assert!(copy_id != local.id && !copy.metadata.is_enabled);
    let body = crate::crypto::open_record(
        &seal,
        &root,
        &saved.salt().unwrap(),
        &saved.kid,
        copy_id,
        false,
    )
    .unwrap();
    assert_eq!(
        body.as_slice(),
        fixture["plaintext"].as_str().unwrap().as_bytes()
    );
    assert_eq!(sender.send(&mut server, 4).unwrap().status, Status::Settled);
    assert_eq!(server.records.len(), 2);
    assert!(server.submitted[0][0].record == offered.record);
    assert!(server.submitted[0][0].expected_record_version == offered.expected_record_version);
    assert_eq!(server.submitted[1][0].record.id, copy_id);
    assert_eq!(server.submitted[2][0].record.id, local.id);
    assert!(
        server.submitted[2][0].expected_record_version.as_ref() == Some(&authoritative_version)
    );
    let saved = crate::vault::read_document(temporary.path())
        .unwrap()
        .unwrap();
    assert_eq!(saved.records[0].sealed.text(), seal.text());
    assert_eq!(
        server.body(local.id),
        "Public authoritative ordinary winner"
    );
    assert!(!load(&library).journal.has_preservation_work());
}

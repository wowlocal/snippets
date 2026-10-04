//! Saved-page continuation uses real encrypted files and a fictional peer.
use super::*;
use crate::{materializer::Keyring, vault::Document};
fn setup() -> (tempfile::TempDir, Library, Document, Envelope) {
    let temporary = tempfile::tempdir().unwrap();
    let library = Library::open(temporary.path().into()).unwrap();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
    fs::create_dir(temporary.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &temporary.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let base = crate::projection::current(
        &[],
        Some(&document),
        "11111111",
        &std::collections::BTreeMap::new(),
        &std::collections::BTreeMap::new(),
    )
    .unwrap()
    .into_values()
    .next()
    .unwrap();
    receive_page(&library, vec![record(&base, "base")], "base", true, false);
    let mut incoming = base;
    incoming.hlc = Hlc::foreign(0xffff_0000_0000);
    incoming.fields.as_mut().unwrap().updated_at += 1.0;
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let salt = document.salt().unwrap();
    incoming.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(
        crate::crypto::seal_record(
            b"Public incoming authenticated body",
            &root,
            &salt,
            &document.kid,
            incoming.id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    incoming.extensions.remove("vaultKID");
    incoming.extensions.insert(
        "vaultContentHash".into(),
        crate::canonical::Value::text(crate::crypto::content_hash(
            b"Public incoming authenticated body",
            &root,
            &salt,
        )),
    );
    let progress = receive_page(
        &library,
        vec![record(&incoming, "changed")],
        "changed",
        false,
        false,
    );
    assert_eq!(progress.status, Status::VaultLocked);
    assert!(load(&library).journal.inbox.has_pending_page());
    (temporary, library, document, incoming)
}
#[test]
fn authenticated_receiving_resumes_exact_saved_generation_without_refetching_or_resealing() {
    let (temporary, library, document, incoming) = setup();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &document).unwrap();
    let sync_key = key();
    let binding = scope();
    let mut receiver = owner(&library, &sync_key, &binding, &|| Ok(()));
    receiver.vault_keys = Some(&keys);
    let mut remote = RemoteFixture::new(vec![]);
    let progress = receiver.receive(&mut remote, 1).unwrap();
    assert_eq!(progress.status, Status::Current);
    assert_eq!(progress.applied_records, 1);
    assert!(remote.requested.is_empty());
    let checkpoint = load(&library);
    let confirmed = checkpoint.journal.confirmed(incoming.id).unwrap();
    assert!(confirmed.envelope.encode().unwrap() == incoming.encode().unwrap());
    assert!(confirmed.record_version == record(&incoming, "changed").into_parts().1);
    assert!(checkpoint.journal.inbox.applied_cursor == Some(cursor("changed")));
    let saved = crate::vault::read_document(temporary.path())
        .unwrap()
        .unwrap();
    assert_eq!(
        saved.records[0].sealed.text().as_bytes(),
        incoming.fields.as_ref().unwrap().content.as_slice()
    );
    let body = crate::crypto::open_record(
        &saved.records[0].sealed,
        &root,
        &saved.salt().unwrap(),
        &saved.kid,
        incoming.id,
        false,
    )
    .unwrap();
    assert_eq!(body.as_slice(), b"Public incoming authenticated body");
}
#[test]
fn incorrect_vault_key_keeps_the_saved_page_and_original_confirmed_version() {
    let (temporary, library, document, incoming) = setup();
    let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
    let root = RootKey::from_bytes(&[0x22; 32]).unwrap();
    let keys = Keyring::new(&root, &document).unwrap();
    let sync_key = key();
    let binding = scope();
    let mut receiver = owner(&library, &sync_key, &binding, &|| Ok(()));
    receiver.vault_keys = Some(&keys);
    let mut remote = RemoteFixture::new(vec![]);
    assert!(receiver.receive(&mut remote, 1).is_err());
    assert!(remote.requested.is_empty());
    assert_eq!(
        fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
        before
    );
    let checkpoint = load(&library);
    assert!(
        checkpoint
            .journal
            .inbox
            .next()
            .unwrap()
            .envelope
            .encode()
            .unwrap()
            == incoming.encode().unwrap()
    );
    assert!(
        checkpoint
            .journal
            .confirmed(incoming.id)
            .unwrap()
            .record_version
            == record(&incoming, "base").into_parts().1
    );
}

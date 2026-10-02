//! Retained vault headers follow the reviewed snapshot, never the later vault.
use super::*;
use crate::{
    key_store::{history, restoration as restore},
    vault::{Document, RecoveryHeader},
};

fn install_vault(s: &Setup) -> Document {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let document = Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    std::fs::create_dir_all(s.temp.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    document
}
fn select(s: &mut Setup) -> restore::Selection {
    history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone()
}
pub(super) fn rewrite_legacy(s: &mut Setup, schema: i64) {
    s.store
        .transaction(|owner| {
            let before = owner.read(Slot::AccountReview)?.unwrap();
            let value = canonical::parse(&before).unwrap();
            let fields = value.as_object().unwrap();
            let mut entries = fields["entries"].as_array().unwrap().to_vec();
            for entry in &mut entries {
                let Value::Object(entry) = entry else {
                    unreachable!()
                };
                entry.remove("vaultHeader");
                if schema == 1 {
                    entry.remove("phase");
                    entry.insert("completed".into(), Value::Bool(true));
                }
            }
            let after = object([
                ("schema", Value::Int(schema)),
                ("generation", fields["generation"].clone()),
                ("entries", Value::Array(entries)),
            ])
            .encode()
            .unwrap();
            owner.replace(Slot::AccountReview, Some(&before), Some(&after))
        })
        .unwrap();
}

#[test]
fn completed_switch_keeps_the_reviewed_vault_header_after_vault_replacement() {
    let mut s = setup();
    let mut document = install_vault(&s);
    let expected = RecoveryHeader::retain(&document).unwrap();
    let reviewed = prepare(&mut s).unwrap();
    assert!(s.backend.memory.slot(Slot::AccountReview).is_none());
    assert!(reviewed.entry.vault_header.as_ref() == Some(&expected));
    commit(&mut s, reviewed).unwrap();
    let selection = select(&mut s);
    document.kid = "Public replacement vault identity".into();
    document.vault_salt = crate::crypto::b64(&[0x55; 32]);
    document.records.clear();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let before = capabilities(&s);
    let selected = restore::saved_vault_header(&mut s.store, &selection).unwrap();
    assert!(selected.as_ref() == Some(&expected));
    assert!(capabilities(&s) == before);
    let bytes = s.backend.memory.slot(Slot::AccountReview).unwrap();
    let value = canonical::parse(&bytes).unwrap();
    assert_eq!(value.as_object().unwrap()["schema"].as_int().unwrap(), 4);
    let fields = value.as_object().unwrap()["entries"].as_array().unwrap()[0]
        .as_object()
        .unwrap();
    let header = STANDARD
        .decode(fields["vaultHeader"].as_text().unwrap())
        .unwrap();
    let value: serde_json::Value = serde_json::from_slice(&header).unwrap();
    assert!(value.get("records").is_none());
}

fn capabilities(s: &Setup) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::CheckpointKey,
        Slot::AccountReview,
        Slot::Credentials,
    ]
    .into_iter()
    .map(|slot| s.backend.memory.slot(slot))
    .collect()
}

#[test]
fn cancelled_switch_retains_its_old_header_beside_later_vault_edits() {
    let mut s = setup();
    let mut document = install_vault(&s);
    let expected = RecoveryHeader::retain(&document).unwrap();
    pending_before_publication(&mut s);
    document.kid = "Public later edited vault".into();
    document.records.clear();
    let later = document.encode().unwrap();
    crate::model::atomic_write(&s.temp.path().join("Vault/vault.json"), &later).unwrap();
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    handover::cancel(&mut s.store, permit).unwrap();
    let selection = select(&mut s);
    assert!(
        restore::saved_vault_header(&mut s.store, &selection)
            .unwrap()
            .as_ref()
            == Some(&expected)
    );
    assert!(std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap() == later);
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    assert!(
        archive.entries[0].cancelled && archive.entries[0].vault_header.as_ref() == Some(&expected)
    );
}

#[test]
fn interrupted_key_slot_activation_keeps_the_same_header_across_every_lost_reply() {
    for call in 1..=7 {
        for after in [false, true] {
            let mut s = setup();
            let document = install_vault(&s);
            let expected = RecoveryHeader::retain(&document).unwrap();
            let reviewed = prepare(&mut s).unwrap();
            s.backend.arm(call, after);
            assert!(commit(&mut s, reviewed).is_err());
            s.backend.arm(usize::MAX, false);
            s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
            if s.backend.memory.slot(Slot::AccountReview).is_none() {
                let reviewed = prepare(&mut s).unwrap();
                commit(&mut s, reviewed).unwrap();
            } else if handover::inspect(&mut s.store).unwrap().pending {
                resume(&mut s).unwrap();
            }
            let selection = select(&mut s);
            assert!(
                restore::saved_vault_header(&mut s.store, &selection)
                    .unwrap()
                    .as_ref()
                    == Some(&expected)
            );
            assert!(
                std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap()
                    == document.encode().unwrap()
            );
        }
    }
}

#[test]
fn legacy_switches_keep_an_explicitly_missing_header_through_schema_upgrade() {
    for schema in [1, 2] {
        let mut s = setup();
        install_vault(&s);
        let reviewed = prepare(&mut s).unwrap();
        commit(&mut s, reviewed).unwrap();
        rewrite_legacy(&mut s, schema);
        let selection = select(&mut s);
        assert!(
            restore::saved_vault_header(&mut s.store, &selection)
                .unwrap()
                .is_none()
        );
        let before = capabilities(&s);
        s.store
            .transaction_with(|owner| {
                let mut archive = handover::Archive::load(owner)?;
                archive.save(owner)
            })
            .unwrap();
        let selection = select(&mut s);
        assert!(
            restore::saved_vault_header(&mut s.store, &selection)
                .unwrap()
                .is_none()
        );
        let after = capabilities(&s);
        assert!(before[..3] == after[..3] && before[4] == after[4]);
    }
}

#[test]
fn a_full_legacy_archive_migrates_without_adding_empty_header_fields_or_evicting_capabilities() {
    let mut s = setup();
    install_vault(&s);
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    rewrite_legacy(&mut s, 2);
    let before = s.backend.memory.slot(Slot::AccountReview).unwrap();
    let value = canonical::parse(&before).unwrap();
    let encode = |size| {
        let mut value = value.clone();
        let Value::Object(ref mut fields) = value else {
            unreachable!()
        };
        let Value::Array(ref mut entries) = *fields.get_mut("entries").unwrap() else {
            unreachable!()
        };
        let Value::Object(ref mut entry) = entries[0] else {
            unreachable!()
        };
        let Value::Object(ref mut source) = *entry.get_mut("source").unwrap() else {
            unreachable!()
        };
        source.insert(
            "pairingRecipient".into(),
            Value::text(STANDARD.encode(vec![0x55; size])),
        );
        value.encode().unwrap()
    };
    let (mut low, mut high) = (0, secret_store::MAX_SECRET_BYTES);
    while low < high {
        let middle = low + (high - low).div_ceil(2);
        if encode(middle).len() <= secret_store::MAX_SECRET_BYTES {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    let full = encode(low);
    assert!(secret_store::MAX_SECRET_BYTES - full.len() < 4);
    s.store
        .transaction(|owner| owner.replace(Slot::AccountReview, Some(&before), Some(&full)))
        .unwrap();
    s.store
        .transaction_with(|owner| {
            let mut archive = handover::Archive::load(owner)?;
            assert!(archive.entries[0].vault_header.is_none());
            archive.save(owner)
        })
        .unwrap();
    let after = s.backend.memory.slot(Slot::AccountReview).unwrap();
    assert_eq!(after.len(), full.len());
    let value = canonical::parse(&after).unwrap();
    assert_eq!(value.as_object().unwrap()["schema"].as_int().unwrap(), 4);
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    assert!(archive.entries[0].completed);
    assert!(archive.entries[0].source[2].as_deref() == Some(&vec![0x55; low]));
    assert!(archive.entries[0].vault_header.is_none());
}

#[test]
fn retained_header_selection_is_bound_to_the_whole_protected_history_generation() {
    let mut s = setup();
    install_vault(&s);
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    let selection = select(&mut s);
    s.store
        .transaction_with(|owner| {
            let mut archive = handover::Archive::load(owner)?;
            archive.save(owner)
        })
        .unwrap();
    let before = capabilities(&s);
    assert!(matches!(
        restore::saved_vault_header(&mut s.store, &selection),
        Err(restore::Failure::Changed)
    ));
    assert!(capabilities(&s) == before);
    let selection = select(&mut s);
    assert!(
        restore::saved_vault_header(&mut s.store, &selection)
            .unwrap()
            .is_some()
    );
}

#[test]
fn changed_vault_between_review_and_commit_cannot_publish_a_different_header() {
    let mut s = setup();
    let mut document = install_vault(&s);
    let reviewed = prepare(&mut s).unwrap();
    document.kid = "Public concurrently replaced vault".into();
    let later = document.encode().unwrap();
    crate::model::atomic_write(&s.temp.path().join("Vault/vault.json"), &later).unwrap();
    assert!(commit(&mut s, reviewed).is_err());
    assert!(s.backend.memory.slot(Slot::AccountReview).is_none());
    assert!(std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap() == later);
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
    assert!(!s.temp.path().join("Sync/Reviews").exists());
}

#[test]
fn invalid_header_fences_the_entire_archive_without_touching_active_capabilities() {
    for kind in 0..3 {
        let mut s = setup();
        install_vault(&s);
        let reviewed = prepare(&mut s).unwrap();
        let mut entry = reviewed.entry.value().unwrap();
        let Value::Object(ref mut fields) = entry else {
            unreachable!()
        };
        let bytes = match kind {
            0 => b"{\"schemaVersion\":2}".to_vec(),
            1 => {
                let bytes = STANDARD
                    .decode(fields["vaultHeader"].as_text().unwrap())
                    .unwrap();
                let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                value
                    .as_object_mut()
                    .unwrap()
                    .insert("records".into(), serde_json::Value::Array(Vec::new()));
                serde_json::to_vec(&value).unwrap()
            }
            _ => vec![b' '; crate::vault::MAX_HEADER_BYTES + 1],
        };
        fields.insert("vaultHeader".into(), Value::text(STANDARD.encode(bytes)));
        let archive = object([
            ("schema", Value::Int(3)),
            ("generation", Value::Int(1)),
            ("entries", Value::Array(vec![entry])),
        ])
        .encode()
        .unwrap();
        s.store
            .transaction(|owner| owner.replace(Slot::AccountReview, None, Some(&archive)))
            .unwrap();
        let before = capabilities(&s);
        assert!(handover::inspect(&mut s.store).is_err());
        assert!(
            s.store
                .transaction_with(|owner| check_admission_locked(owner, &s.remote.pin))
                .is_err()
        );
        assert!(capabilities(&s) == before);
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
    }
}

#[test]
fn oversized_header_refuses_before_retention_or_consent_while_catalogue_extras_are_not_retained() {
    let mut s = setup();
    let mut document = install_vault(&s);
    document.extra.insert(
        "Public catalogue-only sentinel".into(),
        serde_json::Value::from("a".repeat(crate::vault::MAX_HEADER_BYTES * 2)),
    );
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    assert!(prepare(&mut s).is_ok());
    document.kdf.extra.insert(
        "Public unbounded KDF parameter".into(),
        serde_json::Value::from("a".repeat(crate::vault::MAX_HEADER_BYTES)),
    );
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let before = capabilities(&s);
    assert!(prepare(&mut s).is_err());
    assert!(capabilities(&s) == before);
    assert!(!s.temp.path().join("Sync/Reviews").exists());
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
}

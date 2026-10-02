//! Test-only fictional keys/seals. No native desktop, keyring or external data.
use super::*;
use std::cell::Cell;

#[test]
fn unauthenticated_or_unsupported_history_images_never_replace_the_current_body() {
    let (_temp, _library, mut vault) = super::super::tests::setup();
    let record = vault.document.as_ref().unwrap().records[0].clone();
    let mut draft = vault
        .protect_draft(
            record.metadata.clone(),
            b"Current public draft",
            Some(record.clone()),
        )
        .unwrap();
    let binding = vault.edit_binding(&draft).unwrap();
    for damage in 0..6 {
        let mut image = vault.capture_edit(&draft, &binding).unwrap();
        let document = vault.document.as_ref().unwrap();
        let key = &vault.session.as_ref().unwrap().key;
        image.sealed = match damage {
            0 => crypto::seal_record(
                b"Wrong public AAD",
                key,
                &document.salt().unwrap(),
                &document.kid,
                record.metadata.id,
                false,
            )
            .unwrap(),
            1 => crypto::seal_draft(
                b"Wrong public record",
                key,
                &document.salt().unwrap(),
                &document.kid,
                Uuid::from_u128(99),
            )
            .unwrap(),
            2 => crypto::seal_draft(
                b"\xff",
                key,
                &document.salt().unwrap(),
                &document.kid,
                record.metadata.id,
            )
            .unwrap(),
            3 => crypto::seal_draft(
                b"\0",
                key,
                &document.salt().unwrap(),
                &document.kid,
                record.metadata.id,
            )
            .unwrap(),
            4 => {
                let (prefix, encoded) = image.sealed.text().rsplit_once('.').unwrap();
                let mut bytes = crypto::unb64(encoded).unwrap();
                bytes[0] ^= 1;
                Sealed::parse(format!("{prefix}.{}", crypto::b64(&bytes))).unwrap()
            }
            5 => crypto::seal_draft(
                b"Wrong public key",
                &RootKey::from_bytes(&[0x22; 32]).unwrap(),
                &document.salt().unwrap(),
                &document.kid,
                record.metadata.id,
            )
            .unwrap(),
            _ => unreachable!(),
        };
        let before = draft.clone();
        let called = Cell::new(false);
        assert!(
            vault
                .restore_edit(&mut draft, &binding, &image, |_, _| {
                    called.set(true);
                    Ok(())
                })
                .is_err()
        );
        assert!(!called.get() && draft == before);
    }
}

#[test]
fn current_seal_authentication_and_callback_validation_precede_any_snapshot_replacement() {
    let (_temp, _library, mut vault) = super::super::tests::setup();
    let record = vault.document.as_ref().unwrap().records[0].clone();
    let mut draft = vault
        .protect_draft(
            record.metadata.clone(),
            b"Previous public draft",
            Some(record.clone()),
        )
        .unwrap();
    let binding = vault.edit_binding(&draft).unwrap();
    let image = vault.capture_edit(&draft, &binding).unwrap();
    draft = vault
        .protect_draft(
            record.metadata.clone(),
            b"Current public draft",
            Some(record.clone()),
        )
        .unwrap();
    let before = draft.clone();
    let called = Cell::new(false);
    assert!(
        vault
            .restore_edit(&mut draft, &binding, &image, |current, previous| {
                called.set(true);
                assert!(current == b"Current public draft" && previous == b"Previous public draft");
                Err(Error("Public refused validation"))
            })
            .is_err()
    );
    assert!(called.get() && draft == before);
    let document = vault.document.as_ref().unwrap();
    draft.sealed = crypto::seal_record(
        b"Public current wrong AAD",
        &vault.session.as_ref().unwrap().key,
        &document.salt().unwrap(),
        &document.kid,
        record.metadata.id,
        false,
    )
    .unwrap();
    let before = draft.clone();
    called.set(false);
    assert!(
        vault
            .restore_edit(&mut draft, &binding, &image, |_, _| {
                called.set(true);
                Ok(())
            })
            .is_err()
    );
    assert!(!called.get() && draft == before);
}

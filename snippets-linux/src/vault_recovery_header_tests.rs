use super::*;

fn document() -> Document {
    let fixture: Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap()
}

#[test]
fn retained_wraps_authenticate_after_the_catalogue_is_gone_without_retaining_record_data() {
    let mut source = document();
    source.records[0].metadata.name = "Public header-only metadata sentinel".into();
    source
        .extra
        .insert("unrelatedMetadata".into(), Value::Bool(true));
    let header = RecoveryHeader::retain(&source).unwrap();
    assert!(header.has_passphrase() && header.has_recovery());
    let bytes = header.encode_secret().unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value.as_object().unwrap().len(), 7);
    assert!(value.get("records").is_none() && value.get("unrelatedMetadata").is_none());
    assert!(
        !bytes
            .windows(source.records[0].metadata.name.len())
            .any(|window| window == source.records[0].metadata.name.as_bytes())
    );
    assert!(bytes.len() <= MAX_HEADER_BYTES);
    let expected = RootKey::from_bytes(&[0x11; 32]).unwrap();
    drop(source);
    let header = RecoveryHeader::decode_secret(&bytes).unwrap();
    let authenticated = header.authenticate("Café public fixture", false).unwrap();
    assert!(authenticated.key.same_key(&expected));
    let recovery = crypto::format_recovery(&[0x66; 16]);
    assert!(
        header
            .authenticate(&recovery, true)
            .unwrap()
            .key
            .same_key(&expected)
    );
    assert!(
        header
            .authenticate("Public wrong fixture password", false)
            .is_err()
    );
    assert!(header.authenticate(&"a".repeat(4097), false).is_err());
}

#[test]
fn malformed_or_widened_protected_headers_are_rejected_before_authentication() {
    let mut future = document();
    future.schema_version = 2;
    assert!(RecoveryHeader::retain(&future).is_err());
    let header = RecoveryHeader::retain(&document()).unwrap();
    let bytes = header.encode_secret().unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    for kind in 0..7 {
        let mut value = value.clone();
        let fields = value.as_object_mut().unwrap();
        match kind {
            0 => {
                fields.insert("schemaVersion".into(), Value::from(2));
            }
            1 => {
                fields.insert("records".into(), Value::Array(Vec::new()));
            }
            2 => {
                fields.insert("kid".into(), Value::from(""));
            }
            3 => {
                fields.insert("vaultSalt".into(), Value::from(crypto::b64(&[0; 31])));
            }
            4 => {
                fields.insert("wrapPass".into(), Value::from("Public invalid seal"));
            }
            5 => {
                fields.insert("kid".into(), Value::from("a".repeat(257)));
            }
            _ => {
                fields.insert("body".into(), Value::from("Public forbidden body"));
            }
        }
        assert!(RecoveryHeader::decode_secret(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    assert!(RecoveryHeader::decode_secret(&vec![b' '; MAX_HEADER_BYTES + 1]).is_err());
    let duplicate = bytes.strip_suffix(b"}").unwrap();
    let mut duplicate = duplicate.to_vec();
    duplicate.extend_from_slice(b",\"schemaVersion\":1}");
    assert!(RecoveryHeader::decode_secret(&duplicate).is_err());
}

#[test]
fn recovery_owner_expires_across_suspension_and_wall_changes_before_borrowing_a_key() {
    let header = RecoveryHeader::retain(&document()).unwrap();
    let mut owner = header
        .authenticate_for_restoration(&crypto::format_recovery(&[0x66; 16]), true)
        .unwrap();
    assert!(
        owner
            .validate_at(
                owner.started + Duration::from_secs(119),
                owner.wall + Duration::from_secs(119)
            )
            .is_ok()
    );
    assert!(
        owner
            .validate_at(owner.started + Duration::from_secs(120), owner.wall)
            .is_err()
    );
    assert!(
        owner
            .validate_at(owner.started, owner.wall + Duration::from_secs(120))
            .is_err()
    );
    assert!(
        owner
            .validate_at(owner.started, owner.wall - Duration::from_secs(1))
            .is_err()
    );
    owner.wall -= Duration::from_secs(121);
    assert!(
        owner
            .with_keys(|_| panic!("An expired source owner must not borrow its key"))
            .is_err()
    );
}

#[test]
fn all_source_owners_are_bounded_before_any_multi_key_operation() {
    let header = RecoveryHeader::retain(&document()).unwrap();
    let first = header
        .backup_owner(
            RootKey::from_bytes(&[0x11; 32]).unwrap(),
            crate::clock::uptime().unwrap(),
            std::time::SystemTime::now(),
        )
        .unwrap();
    let mut second = header
        .backup_owner(
            RootKey::from_bytes(&[0x11; 32]).unwrap(),
            crate::clock::uptime().unwrap(),
            std::time::SystemTime::now(),
        )
        .unwrap();
    assert_eq!(
        RecoveryOwner::with_many_keys(&[&first, &second], |keys| keys.len()).unwrap(),
        2
    );
    second.wall -= Duration::from_secs(121);
    assert!(
        RecoveryOwner::with_many_keys(&[&first, &second], |_| panic!(
            "A later expired source must refuse every key borrow"
        ))
        .is_err()
    );
    assert!(
        RecoveryOwner::with_many_keys(&[], |_| panic!(
            "Missing source owners must refuse borrowing"
        ))
        .is_err()
    );
    assert!(
        RecoveryOwner::with_many_keys(&[&first; 9], |_| panic!(
            "Too many source owners must refuse borrowing"
        ))
        .is_err()
    );
}

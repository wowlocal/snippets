//! Public fixtures only. Expected bytes come from OpenSSL and existing Apple/
//! Android tests, never from the Rust implementation under test.
use super::*;
use serde_json::{Value as JSON, json};
fn fixture() -> JSON {
    serde_json::from_str(include_str!("../tests/fixtures/bootstrap-v1.json")).unwrap()
}
fn bytes(value: &JSON) -> Vec<u8> {
    STANDARD.decode(value.as_str().unwrap()).unwrap()
}
fn bundle() -> Bundle {
    Bundle::from_material(&bytes(&fixture()["material"])).unwrap()
}
fn invitation() -> Invitation {
    Invitation::decode_qr(
        fixture()["pairing"]["invitationJSON"]
            .as_str()
            .unwrap()
            .as_bytes(),
        1700000000,
    )
    .unwrap()
}
fn draft() -> PairingDraft {
    let f = fixture();
    let invitation = invitation();
    let bytes = serde_json::to_vec(&json!({"recipientPublicKey":STANDARD.encode(invitation.recipient),"nonce":STANDARD.encode(invitation.nonce),"privateKey":f["pairing"]["recipientPrivate"]})).unwrap();
    PairingDraft::decode_secret(&bytes).unwrap()
}
fn pending() -> PendingPairing {
    PendingPairing::new(draft(), invitation()).unwrap()
}
fn kit() -> RecoveryKit {
    RecoveryKit::decode_secret_qr(fixture()["recovery"]["qrJSON"].as_str().unwrap().as_bytes())
        .unwrap()
}
fn rejected_qr(value: &JSON) -> bool {
    Invitation::decode_qr(&serde_json::to_vec(value).unwrap(), 1700000000).is_err()
}
fn assert_material(value: &Bundle) {
    assert!(*value.for_secure_storage() == bytes(&fixture()["material"]).as_slice());
}

#[test]
fn portable_bundle_matches_frozen_swift_sorted_json_and_material() {
    let f = fixture();
    let expected = f["bundleJSON"].as_str().unwrap().as_bytes();
    assert!(bundle().encode_secret().unwrap().as_slice() == expected);
    assert_material(&Bundle::decode(expected).unwrap());
    for bad in [
        br#"{"key":"a","key":"a","schemaVersion":1,"scopeID":"sync-v1","salt":"a"}"#.as_slice(),
        br#"[]"#,
    ] {
        assert!(Bundle::decode(bad).is_err());
    }
    let original: JSON = serde_json::from_slice(expected).unwrap();
    for field in ["schemaVersion", "scopeID", "key", "salt", "extra"] {
        let mut value = original.clone();
        value[field] = match field {
            "schemaVersion" => json!(1.0),
            "scopeID" => json!("vault-v1"),
            "extra" => json!(true),
            _ => json!("A".repeat(44)),
        };
        assert!(Bundle::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    assert!(Bundle::from_material(&[0; 63]).is_err());
    assert!(Bundle::decode(&vec![b' '; 2049]).is_err());
}

#[test]
fn p256_pairing_matches_independent_openssl_ecdh_hkdf_and_aes_bytes() {
    let f = fixture();
    let pairing = &f["pairing"];
    let invitation = invitation();
    assert!(
        invitation.encode_qr().unwrap().as_slice()
            == pairing["invitationJSON"].as_str().unwrap().as_bytes()
    );
    assert!(invitation.confirmation_code() == pairing["confirmationCode"].as_str().unwrap());
    let sender = SecretKey::from_slice(&bytes(&pairing["senderPrivate"])).unwrap();
    let nonce = bytes(&pairing["nonce"]).try_into().unwrap();
    let ciphertext = seal_pairing_with(&bundle(), &invitation, 1700000000, &sender, nonce).unwrap();
    assert!(ciphertext == pairing["envelopeJSON"].as_str().unwrap().as_bytes());
    assert_material(&open_pairing(&ciphertext, &pending(), 1700000000).unwrap());
    assert!(
        pairing_request_hash(invitation.pairing, &invitation.recipient, &ciphertext).unwrap()
            == bytes(&pairing["requestHash"]).as_slice()
    );
}

#[test]
fn independent_recovery_fixture_also_matches_the_existing_apple_and_android_vector() {
    let f = fixture();
    let expected = bytes(&f["recovery"]["ciphertext"]);
    let kit = kit();
    assert_material(&open_recovery(&expected, &kit).unwrap());
    let nonce = bytes(&f["recovery"]["nonce"]).try_into().unwrap();
    assert!(seal_recovery_with(&bundle(), &kit, nonce).unwrap() == expected);
    assert!(
        kit.encode_secret_qr().unwrap().as_slice()
            == f["recovery"]["qrJSON"].as_str().unwrap().as_bytes()
    );
    assert!(kit.encode_secret_code().as_str() == f["recovery"]["code"].as_str().unwrap());
    assert!(
        recovery_request_hash(7, None, &expected).unwrap()
            == bytes(&f["recovery"]["createHash"]).as_slice()
    );
    assert!(
        recovery_request_hash(7, Some(1), &expected).unwrap()
            == bytes(&f["recovery"]["replaceHash"]).as_slice()
    );
}

#[test]
fn ed25519_authority_and_signatures_match_swift_and_openssl_and_bind_every_coordinate() {
    let f = fixture();
    let v = &f["authority"];
    let server = ServerURL::parse("https://sync.example").unwrap();
    let instance = Uuid::parse_str(v["serverInstanceId"].as_str().unwrap()).unwrap();
    let space = Uuid::parse_str(v["spaceId"].as_str().unwrap()).unwrap();
    let context = AuthorityContext::new(server.clone(), instance, space).unwrap();
    let authority = Authority::new(&bundle(), &context);
    assert!(authority.public_key() == bytes(&v["publicKey"]).as_slice());
    let proof = authority.sign(Uuid::from_u128(123), &[7; 32]).unwrap();
    assert!(proof.signature.as_slice() == bytes(&v["signature"]));
    let key = ed25519_dalek::VerifyingKey::from_bytes(&authority.public_key()).unwrap();
    let mut message = b"snippets-library-action-proof-v1\n".to_vec();
    message.extend_from_slice(&[7; 32]);
    key.verify_strict(
        &message,
        &ed25519_dalek::Signature::from_bytes(proof.signature()),
    )
    .unwrap();
    let encoded: JSON = serde_json::from_slice(&proof.encode().unwrap()).unwrap();
    assert!(encoded["challengeId"] == Uuid::from_u128(123).to_string());
    assert!(encoded["signature"] == v["signature"]);
    for changed in [
        AuthorityContext::new(
            ServerURL::parse("https://another.example").unwrap(),
            instance,
            space,
        )
        .unwrap(),
        AuthorityContext::new(server.clone(), Uuid::from_u128(7), space).unwrap(),
        AuthorityContext::new(server.clone(), instance, Uuid::from_u128(8)).unwrap(),
    ] {
        assert!(Authority::new(&bundle(), &changed).public_key() != authority.public_key());
    }
    assert!(
        AuthorityContext::new(
            ServerURL::parse("https://sync.example/subpath").unwrap(),
            instance,
            space
        )
        .is_err()
    );
    assert!(AuthorityContext::new(server, Uuid::nil(), space).is_err());
    assert!(authority.sign(Uuid::nil(), &[7; 32]).is_err());
}

#[test]
fn pairing_envelopes_authenticate_aad_sender_nonce_ciphertext_and_plaintext_schema() {
    let f = fixture();
    let raw = f["pairing"]["envelopeJSON"].as_str().unwrap().as_bytes();
    let original: JSON = serde_json::from_slice(raw).unwrap();
    for field in [
        "nonce",
        "sealed",
        "senderPublicKey",
        "schemaVersion",
        "extra",
    ] {
        let mut v = original.clone();
        v[field] = match field {
            "schemaVersion" => json!(2),
            "extra" => json!(true),
            "senderPublicKey" => json!(URL_SAFE_NO_PAD.encode(invitation().recipient)),
            _ => {
                let mut bytes = URL_SAFE_NO_PAD.decode(v[field].as_str().unwrap()).unwrap();
                bytes[0] ^= 1;
                json!(URL_SAFE_NO_PAD.encode(bytes))
            }
        };
        assert!(open_pairing(&serde_json::to_vec(&v).unwrap(), &pending(), 1700000000).is_err());
    }
    for mutation in 0..5 {
        let mut invitation = invitation();
        match mutation {
            0 => invitation.server = ServerURL::parse("https://foreign.example").unwrap(),
            1 => invitation.space = Uuid::from_u128(9),
            2 => invitation.pairing = Uuid::from_u128(10),
            3 => invitation.nonce[0] ^= 1,
            _ => invitation.recipient = public_bytes(&SecretKey::from_slice(&[2; 32]).unwrap()),
        }
        if let Ok(pending) = PendingPairing::new(draft(), invitation) {
            assert!(open_pairing(raw, &pending, 1700000000).is_err());
        }
    }
    assert!(open_pairing(raw, &pending(), 1700000330).err() == Some(Failure::Expired));
    assert!(open_pairing(&vec![0; 4097], &pending(), 1700000000).is_err());
    // Correct GCM under the invitation still cannot install a malformed bundle.
    let recipient = draft();
    let sender = SecretKey::from_slice(&bytes(&f["pairing"]["senderPrivate"])).unwrap();
    let aad = invitation().aad();
    let shared = sender.diffie_hellman(&parse_public(&recipient.public).unwrap());
    let key = derive(shared.raw_secret_bytes().as_ref(), &recipient.nonce, &aad);
    let nonce = [1; 12];
    let sealed = encrypt(br#"{"schemaVersion":2}"#, &key, nonce, &aad).unwrap();
    let bad = serde_json::to_vec(&json!({"schemaVersion":1,"senderPublicKey":URL_SAFE_NO_PAD.encode(public_bytes(&sender)),"nonce":URL_SAFE_NO_PAD.encode(nonce),"sealed":URL_SAFE_NO_PAD.encode(sealed)})).unwrap();
    assert!(open_pairing(&bad, &pending(), 1700000000).err() == Some(Failure::Authentication));
}

#[test]
fn recovery_authenticates_every_binding_and_rejects_invalid_combined_layout() {
    let f = fixture();
    let ciphertext = bytes(&f["recovery"]["ciphertext"]);
    for mutation in 0..4 {
        let mut kit = kit();
        match mutation {
            0 => kit.server = ServerURL::parse("https://foreign.example").unwrap(),
            1 => kit.space = Uuid::from_u128(99),
            2 => kit.epoch += 1,
            _ => kit.secret[0] ^= 1,
        };
        assert!(open_recovery(&ciphertext, &kit).err() == Some(Failure::Authentication));
    }
    for index in [0, 12, ciphertext.len() - 1] {
        let mut corrupted = ciphertext.clone();
        corrupted[index] ^= 1;
        assert!(open_recovery(&corrupted, &kit()).err() == Some(Failure::Authentication));
    }
    for length in [0, 12, 27, 4097] {
        assert!(open_recovery(&vec![0; length], &kit()).err() == Some(Failure::InvalidFormat));
    }
}

#[test]
fn recovery_code_supports_case_whitespace_and_grouping_but_refuses_padding_and_confusables() {
    let f = fixture();
    let code = f["recovery"]["code"].as_str().unwrap();
    let kit = kit();
    let ciphertext = bytes(&f["recovery"]["ciphertext"]);
    let code_variant = format!(
        "\t{}\u{2003}\n",
        code.to_ascii_lowercase().replace('-', " ")
    );
    let decoded =
        RecoveryKit::decode_secret_code(&code_variant, kit.server.clone(), kit.space, kit.epoch)
            .unwrap();
    assert_material(&open_recovery(&ciphertext, &decoded).unwrap());
    let compact = code.replace('-', "");
    for index in 0..compact.len() {
        let mut bad = compact.clone().into_bytes();
        bad[index] = b'O';
        assert!(
            RecoveryKit::decode_secret_code(
                std::str::from_utf8(&bad).unwrap(),
                kit.server.clone(),
                kit.space,
                kit.epoch
            )
            .is_err()
        );
    }
    let mut noncanonical = compact.into_bytes();
    let last = ALPHABET
        .iter()
        .position(|b| *b == *noncanonical.last().unwrap())
        .unwrap();
    *noncanonical.last_mut().unwrap() = ALPHABET[last + 1];
    assert!(
        RecoveryKit::decode_secret_code(
            std::str::from_utf8(&noncanonical).unwrap(),
            kit.server.clone(),
            kit.space,
            kit.epoch
        )
        .is_err()
    );
    assert!(
        RecoveryKit::decode_secret_code(&" ".repeat(1025), kit.server, kit.space, kit.epoch)
            .is_err()
    );
}

#[test]
fn secret_pairing_restart_requires_matching_private_public_nonce_and_exact_shapes() {
    let p = pending();
    let encoded = p.encode_secret().unwrap();
    let restored = PendingPairing::decode_secret(&encoded, 1700000000).unwrap();
    let f = fixture();
    assert_material(
        &open_pairing(
            f["pairing"]["envelopeJSON"].as_str().unwrap().as_bytes(),
            &restored,
            1700000000,
        )
        .unwrap(),
    );
    let original: JSON = serde_json::from_slice(&encoded).unwrap();
    for mutation in 0..5 {
        let mut v = original.clone();
        match mutation {
            0 => v["draft"]["privateKey"] = json!(STANDARD.encode([0; 32])),
            1 => v["draft"]["privateKey"] = json!(STANDARD.encode([1; 32])),
            2 => v["draft"]["nonce"] = json!(STANDARD.encode([0; 32])),
            3 => v["draft"]["unexpected"] = json!(true),
            _ => v["unexpected"] = json!(true),
        }
        assert!(
            PendingPairing::decode_secret(&serde_json::to_vec(&v).unwrap(), 1700000000).is_err()
        );
    }
    assert!(PendingPairing::decode_secret(&encoded, 1700000330).err() == Some(Failure::Expired));
    assert!(PairingDraft::decode_secret(&vec![0; 4097]).is_err());
}

#[test]
fn invitation_qr_requires_canonical_base64_ids_https_valid_curve_and_integer_schema() {
    let original: JSON = serde_json::from_slice(&invitation().encode_qr().unwrap()).unwrap();
    for mutation in 0..10 {
        let mut v = original.clone();
        match mutation {
            0 => v["schemaVersion"] = json!(2.0),
            1 => v["spaceId"] = json!(Uuid::nil().to_string()),
            2 => v["pairingId"] = json!("30000000000000000000000000000001"),
            3 => v["server"] = json!("http://sync.example"),
            4 => v["server"] = json!("https://user@sync.example"),
            5 => v["server"] = json!("https://sync.example/"),
            6 => v["nonce"] = json!(format!("{}=", v["nonce"].as_str().unwrap())),
            7 => v["recipientPublicKey"] = json!(URL_SAFE_NO_PAD.encode([4; 65])),
            8 => v["recipientPublicKey"] = json!(URL_SAFE_NO_PAD.encode([0; 33])),
            _ => v["unexpected"] = json!(false),
        }
        assert!(rejected_qr(&v));
    }
    let mut uppercase = original.clone();
    uppercase["spaceId"] = json!(uppercase["spaceId"].as_str().unwrap().to_ascii_uppercase());
    assert!(!rejected_qr(&uppercase));
    let duplicate = invitation().encode_qr().unwrap();
    let raw = std::str::from_utf8(&duplicate)
        .unwrap()
        .replacen("{", "{\"schemaVersion\":2,", 1);
    assert!(Invitation::decode_qr(raw.as_bytes(), 1700000000).is_err());
}

#[test]
fn invitation_time_windows_and_overflow_fail_closed_without_extending_an_invitation() {
    let original = invitation();
    for (expiry, valid) in [
        (1700000000 - 30, false),
        (1700000000 - 29, true),
        (1700000630, true),
        (1700000631, false),
    ] {
        assert_eq!(
            Invitation::new(
                original.server.clone(),
                original.space,
                original.pairing,
                original.nonce,
                original.recipient,
                expiry,
                1700000000
            )
            .is_ok(),
            valid
        );
    }
    assert!(original.validate_time(-1).err() == Some(Failure::InvalidFormat));
    assert!(original.validate_time(i64::MAX).err() == Some(Failure::InvalidFormat));
    assert!(seal_pairing(&bundle(), &original, 1700000330).err() == Some(Failure::Expired));
}

#[test]
fn recovery_qr_is_strict_and_action_hashes_are_bounded_and_distinguish_null_cas() {
    let f = fixture();
    let original: JSON = serde_json::from_str(f["recovery"]["qrJSON"].as_str().unwrap()).unwrap();
    for mutation in 0..6 {
        let mut v = original.clone();
        match mutation {
            0 => v["keyEpoch"] = json!(0),
            1 => v["keyEpoch"] = json!(7.0),
            2 => v["kind"] = json!("snippets-pairing"),
            3 => v["secret"] = json!("A".repeat(42)),
            4 => v["secret"] = json!(format!("{}=", v["secret"].as_str().unwrap())),
            _ => v["extra"] = json!(true),
        };
        assert!(RecoveryKit::decode_secret_qr(&serde_json::to_vec(&v).unwrap()).is_err());
    }
    assert!(RecoveryKit::decode_secret_qr(&vec![b' '; 4097]).is_err());
    assert!(
        recovery_request_hash(7, None, b"fictional")
            != recovery_request_hash(7, Some(1), b"fictional")
    );
    for (epoch, version) in [(0, None), (1, Some(0)), (-1, Some(1))] {
        assert!(recovery_request_hash(epoch, version, b"fictional").is_err());
    }
    assert!(recovery_request_hash(1, None, &[0; 4097]).is_err());
    assert!(pairing_request_hash(Uuid::nil(), invitation().public_key(), b"fictional").is_err());
}

#[test]
fn fresh_pairing_and_recovery_use_new_random_keys_nonces_and_no_library_material_in_qr() {
    let bundle = bundle();
    let first = PairingDraft::generate().unwrap();
    let second = PairingDraft::generate().unwrap();
    assert!(first.public != second.public && first.nonce != second.nonce);
    let original = invitation();
    let qr: JSON = serde_json::from_slice(&original.encode_qr().unwrap()).unwrap();
    assert!(qr.get("key").is_none() && qr.get("salt").is_none() && qr.get("privateKey").is_none());
    let a = seal_pairing(&bundle, &original, 1700000000).unwrap();
    let b = seal_pairing(&bundle, &original, 1700000000).unwrap();
    let a: JSON = serde_json::from_slice(&a).unwrap();
    let b: JSON = serde_json::from_slice(&b).unwrap();
    assert!(a["nonce"] != b["nonce"] && a["senderPublicKey"] != b["senderPublicKey"]);
    let a = create_recovery(&bundle, original.server.clone(), original.space, 1).unwrap();
    let b = create_recovery(&bundle, original.server, original.space, 1).unwrap();
    assert!(
        a.kit.secret.as_slice() != b.kit.secret.as_slice()
            && a.ciphertext[..12] != b.ciphertext[..12]
    );
    assert_material(&open_recovery(&a.ciphertext, &a.kit).unwrap());
}

fn device_request() -> DeviceSignIn {
    let invitation = invitation();
    DeviceSignIn::new(
        invitation.server.clone(),
        Uuid::from_u128(0x7a6b5c4d_3e2f_4a1b_8c9d_0e1f2a3b4c5d),
        invitation.nonce,
        invitation.recipient,
        1700000600,
        1700000000,
    )
    .unwrap()
}
fn rejected_device(value: &JSON) -> bool {
    DeviceSignIn::decode_qr(&serde_json::to_vec(value).unwrap(), 1700000000).is_err()
}

#[test]
fn device_sign_in_payload_uses_the_invitation_encoding_rules_and_round_trips() {
    let request = device_request();
    let encoded = request.encode_qr().unwrap();
    let text = std::str::from_utf8(&encoded).unwrap();
    let invitation = invitation();
    // Byte-exact: sorted keys, unescaped slashes, unpadded Base64url, lowercase UUID.
    let expected = format!(
        r#"{{"expiresAt":1700000600,"kind":"snippets-device-sign-in","nonce":"{}","recipientPublicKey":"{}","requestId":"7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d","schemaVersion":1,"server":"{}"}}"#,
        URL_SAFE_NO_PAD.encode(invitation.nonce),
        URL_SAFE_NO_PAD.encode(invitation.recipient),
        invitation.server.for_secure_storage(),
    );
    assert_eq!(text, expected);
    assert!(!text.contains("\\/") && !text.contains('='));
    let decoded = DeviceSignIn::decode_qr(&encoded, 1700000000).unwrap();
    assert!(decoded == request);
    assert!(matches!(
        AddDevice::decode_qr(&encoded, 1700000000).unwrap(),
        AddDevice::SignIn(value) if value == request
    ));
    assert!(matches!(
        AddDevice::decode_qr(&invitation.encode_qr().unwrap(), 1700000000).unwrap(),
        AddDevice::Pairing(value) if value == invitation
    ));
    // The derivation is unchanged: it equals the pairing (and server tag) code.
    assert_eq!(request.confirmation_code(), invitation.confirmation_code());
    assert_eq!(request.confirmation_code().len(), 8);
    // A different recipient or nonce changes the code.
    let other = draft();
    let mut nonce = invitation.nonce;
    nonce[0] ^= 1;
    let changed = DeviceSignIn::new(
        request.server.clone(),
        request.request,
        nonce,
        *other.public_key(),
        1700000600,
        1700000000,
    )
    .unwrap();
    assert_ne!(changed.confirmation_code(), request.confirmation_code());
}

#[test]
fn device_sign_in_payload_is_strict_bounded_and_time_limited() {
    let original: JSON = serde_json::from_slice(&device_request().encode_qr().unwrap()).unwrap();
    for mutation in 0..14 {
        let mut v = original.clone();
        match mutation {
            0 => v["schemaVersion"] = json!(2),
            1 => v["schemaVersion"] = json!(1.0),
            2 => v["kind"] = json!("snippets-pairing"),
            3 => v["requestId"] = json!(Uuid::nil().to_string()),
            4 => v["requestId"] = json!("7a6b5c4d3e2f4a1b8c9d0e1f2a3b4c5d"),
            5 => v["server"] = json!("http://sync.example"),
            6 => v["server"] = json!("https://sync.example/"),
            7 => v["nonce"] = json!(format!("{}=", v["nonce"].as_str().unwrap())),
            8 => v["nonce"] = json!(STANDARD.encode([0xfb; 32])),
            9 => v["recipientPublicKey"] = json!(URL_SAFE_NO_PAD.encode([4; 65])),
            10 => v["unexpected"] = json!(false),
            11 => {
                v.as_object_mut().unwrap().remove("expiresAt");
            }
            12 => v["pollToken"] = json!("sn_d_must-never-appear"),
            _ => v["spaceId"] = json!(Uuid::from_u128(1).to_string()),
        }
        assert!(rejected_device(&v), "{mutation}");
    }
    let mut uppercase = original.clone();
    uppercase["requestId"] = json!(
        uppercase["requestId"]
            .as_str()
            .unwrap()
            .to_ascii_uppercase()
    );
    // Same acceptance as the existing invitation codec; output stays lowercase.
    assert!(!rejected_device(&uppercase));
    let duplicate = device_request().encode_qr().unwrap();
    let raw = std::str::from_utf8(&duplicate)
        .unwrap()
        .replacen("{", "{\"schemaVersion\":1,", 1);
    assert!(DeviceSignIn::decode_qr(raw.as_bytes(), 1700000000).is_err());
    let oversized = format!("{}{}", " ".repeat(MAX_ENVELOPE_BYTES), "{}");
    assert!(DeviceSignIn::decode_qr(oversized.as_bytes(), 1700000000).is_err());
    assert!(AddDevice::decode_qr(br#"{"kind":"snippets-other"}"#, 1700000000).is_err());
    let request = device_request();
    for (expiry, valid) in [
        (1700000000 - 30, false),
        (1700000000 - 29, true),
        (1700000630, true),
        (1700000631, false),
    ] {
        assert_eq!(
            DeviceSignIn::new(
                request.server.clone(),
                request.request,
                request.nonce,
                request.recipient,
                expiry,
                1700000000,
            )
            .is_ok(),
            valid
        );
    }
    assert!(
        DeviceSignIn::decode_qr(&request.encode_qr().unwrap(), 1700000700).err()
            == Some(Failure::Expired)
    );
}

use super::*;
use crate::{
    desktop::{SessionState, SessionWitness},
    key_store::disclosure,
    local_auth::{self, Gate, Purpose, Target},
};
fn permit(target: Target) -> (Gate, local_auth::Permit) {
    let mut gate = Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(target, SessionWitness::test(SessionState::Unlocked, 1))
        .unwrap();
    let authenticated = local_auth::authenticate_fixture(request).unwrap();
    let permit = gate.accept(authenticated).unwrap();
    (gate, permit)
}
fn prepare(store: &mut Store<Memory>, remote: &mut FakeRemote) -> Result<Target> {
    store.transaction_with(|o| Ok(disclosure::prepare_locked(o, remote)?.1))
}
fn reveal(
    store: &mut Store<Memory>,
    remote: &mut FakeRemote,
    permit: local_auth::Permit,
) -> Result<disclosure::Disclosure> {
    store.transaction_with(|o| disclosure::reveal_locked(o, remote, permit))
}
fn shown(store: &mut Store<Memory>, remote: &mut FakeRemote) -> (Gate, disclosure::Disclosure) {
    let target = prepare(store, remote).unwrap();
    let (gate, permit) = permit(target);
    (gate, reveal(store, remote, permit).ok().unwrap())
}
fn suffix(value: &disclosure::Disclosure) -> Zeroizing<String> {
    let mut text = Zeroizing::new(
        value
            .long_code()
            .unwrap()
            .chars()
            .filter(|c| c.is_alphanumeric())
            .rev()
            .take(8)
            .collect::<Vec<_>>(),
    );
    text.reverse();
    Zeroizing::new(text.iter().collect())
}
fn confirm(
    store: &mut Store<Memory>,
    remote: &mut FakeRemote,
    value: disclosure::Disclosure,
    suffix: Zeroizing<String>,
) -> Result<Outcome> {
    store.transaction_with(|o| disclosure::confirm_saved_locked(o, remote, value, suffix))
}
fn metadata_only(memory: &Memory) {
    let bytes = memory.slot(Slot::Bootstrap).unwrap();
    let value = canonical::parse(&bytes).unwrap();
    let root = value.as_object().unwrap();
    assert!(root["schema"].as_int().unwrap() == 2 && matches!(root["pending"], Value::Null));
    let p = root["presentation"].as_object().unwrap();
    assert!(p["kind"].as_text().unwrap() == "verification");
    assert!(!p.contains_key("kit") && !p.contains_key("secret") && !p.contains_key("ciphertext"));
    assert!(p.len() == 7);
}
fn legacy(store: &mut Store<Memory>, memory: &Memory, verified: bool) -> Zeroizing<Vec<u8>> {
    let current = memory.slot(Slot::Bootstrap).unwrap();
    let mut value = canonical::parse(&current).unwrap();
    let Value::Object(root) = &mut value else {
        unreachable!()
    };
    root.insert("schema".into(), Value::Int(1));
    let Value::Object(p) = root.get_mut("presentation").unwrap() else {
        unreachable!()
    };
    assert!(p.remove("kind").unwrap().as_text().unwrap() == "retained");
    if verified {
        // Public synthetic schema-1 recovery fixture: AEAD, key and immutable
        // authority are real; legacy verified status represented supplied input.
        p.insert("status".into(), Value::text("verified_current"));
    }
    let bytes = value.encode().unwrap();
    store
        .transaction(|o| o.replace(Slot::Bootstrap, Some(&current), Some(&bytes)))
        .unwrap();
    bytes
}
#[test]
fn recovery_disclosure_consumes_exact_authority_without_marking_the_kit_saved_and_closes_on_background()
 {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let original = memory.slot(Slot::Bootstrap).unwrap();
    let target = prepare(&mut store, &mut remote).unwrap();
    assert!(target.purpose() == Purpose::RevealRecovery);
    let (mut gate, permit) = permit(target);
    let value = reveal(&mut store, &mut remote, permit).ok().unwrap();
    let v = canonical::parse(&original).unwrap();
    let kit = RecoveryKit::decode_secret_qr(
        &v.as_object().unwrap()["presentation"].as_object().unwrap()["kit"]
            .encode()
            .unwrap(),
    )
    .unwrap();
    assert!(value.qr_payload().unwrap() == kit.encode_secret_qr().unwrap().as_slice());
    assert!(value.long_code().unwrap() == kit.encode_secret_code().as_str());
    assert!(memory.slot(Slot::Bootstrap).unwrap() == original);
    gate.set_foreground(false);
    assert!(
        value.qr_payload().err() == Some(Failure::Authentication(local_auth::Failure::Cancelled))
    );
    assert!(
        value.long_code().err() == Some(Failure::Authentication(local_auth::Failure::Cancelled))
    );
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
}
#[test]
fn changed_generation_wrong_purpose_cancelled_request_and_replaced_envelope_cannot_disclose_a_kit()
{
    for mode in 0..4 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let target = prepare(&mut store, &mut remote).unwrap();
        let target = if mode == 1 {
            Target::new(binding(), Purpose::ApprovePairing, 1, [1; 32]).unwrap()
        } else {
            target
        };
        let (mut gate, permit) = permit(target);
        let original = memory.slot(Slot::LibraryKey).unwrap();
        let expected = match mode {
            0 => {
                store
                    .transaction_with::<_, Failure>(|o| {
                        let mut a = Archive::load(o)?;
                        a.save(o)
                    })
                    .unwrap();
                Failure::Authentication(local_auth::Failure::WrongTarget)
            }
            1 => Failure::Authentication(local_auth::Failure::WrongTarget),
            2 => {
                gate.cancel();
                Failure::Authentication(local_auth::Failure::Cancelled)
            }
            _ => {
                remote.recovery.as_mut().unwrap().version += 1;
                Failure::RecoveryUnavailable
            }
        };
        assert!(reveal(&mut store, &mut remote, permit).err() == Some(expected));
        assert!(memory.slot(Slot::LibraryKey).unwrap() == original);
    }
}
#[test]
fn authenticated_control_plane_disclosure_preserves_recovery_when_a_checkpoint_needs_review() {
    let memory = Memory::default();
    let (temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let mut scope = binding().checkpoint_scope();
    scope.dataset = Binding::from_checkpoint([9; 32]);
    let bytes = checkpoint(&temp, &mut store, scope);
    assert!(load(&mut store, &mut remote).is_err());
    let target = prepare(&mut store, &mut remote).unwrap();
    let (_gate, permit) = permit(target);
    let value = reveal(&mut store, &mut remote, permit).ok().unwrap();
    assert!(!value.long_code().unwrap().is_empty());
    assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == bytes);
    let entered = suffix(&value);
    assert!(
        confirm(&mut store, &mut remote, value, entered).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    metadata_only(&memory);
    assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == bytes);
    assert!(load(&mut store, &mut remote).is_err());
}

#[test]
fn saved_suffix_retires_the_kit_atomically_preserves_the_key_and_cannot_redisclose_after_restart() {
    let memory = Memory::default();
    let (temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let original_key = memory.slot(Slot::LibraryKey).unwrap();
    let (_gate, value) = shown(&mut store, &mut remote);
    let entered = suffix(&value);
    assert!(
        confirm(&mut store, &mut remote, value, entered).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    metadata_only(&memory);
    assert!(memory.slot(Slot::LibraryKey).unwrap() == original_key);
    assert!(prepare(&mut store, &mut remote).err() == Some(Failure::RecoveryUnavailable));
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    assert!(load(&mut store, &mut remote).unwrap().is_some());
    let snapshot = memory.slot(Slot::Bootstrap).unwrap();
    remote.recovery.as_mut().unwrap().ciphertext[12] ^= 1;
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::Replaced
            }
    );
    assert!(memory.slot(Slot::Bootstrap).unwrap() != snapshot);
    metadata_only(&memory);
    assert!(memory.slot(Slot::LibraryKey).unwrap() == original_key);
}
#[test]
fn suffix_verification_rejects_wrong_full_oversized_or_confusable_input_before_any_network_or_write()
 {
    for entered in [
        "",
        "WRONG",
        "ABCDEFGH",
        "01234567",
        "KKKKKKKK",
        "０１２３４５６７",
        "IILLOOUU",
    ] {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let (_gate, value) = shown(&mut store, &mut remote);
        let original = memory.slot(Slot::Bootstrap).unwrap();
        let calls = remote.calls;
        assert!(
            confirm(
                &mut store,
                &mut remote,
                value,
                Zeroizing::new(entered.into())
            )
            .err()
                == Some(Failure::VerificationMismatch)
        );
        assert!(remote.calls == calls && memory.slot(Slot::Bootstrap).unwrap() == original);
    }
    for full in [false, true] {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let (_gate, value) = shown(&mut store, &mut remote);
        let entered = if full {
            Zeroizing::new(value.long_code().unwrap().to_owned())
        } else {
            Zeroizing::new(" ".repeat(129))
        };
        assert!(
            confirm(&mut store, &mut remote, value, entered).err()
                == Some(Failure::VerificationMismatch)
        );
    }
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let (_gate, value) = shown(&mut store, &mut remote);
    let code = suffix(&value);
    let entered = Zeroizing::new(format!(
        "  {} - {}\n",
        code[..4].to_ascii_lowercase(),
        code[4..].to_ascii_lowercase()
    ));
    assert!(confirm(&mut store, &mut remote, value, entered).is_ok());
    metadata_only(&memory);
}
#[test]
fn cancelled_changed_generation_scope_authority_or_envelope_cannot_retire_a_presented_kit() {
    for mode in 0..7 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let (mut gate, value) = shown(&mut store, &mut remote);
        let entered = suffix(&value);
        let original_key = memory.slot(Slot::LibraryKey).unwrap();
        let expected = match mode {
            0 => {
                gate.cancel();
                Failure::Authentication(local_auth::Failure::Cancelled)
            }
            1 => {
                store
                    .transaction_with::<_, Failure>(|o| {
                        let mut archive = Archive::load(o)?;
                        archive.save(o)
                    })
                    .unwrap();
                Failure::Authentication(local_auth::Failure::WrongTarget)
            }
            2 => {
                remote.pin.dataset = Binding::from_checkpoint([8; 32]);
                Failure::ReviewRequired
            }
            3 => {
                remote.public = Some([9; 32]);
                Failure::KeyConflict
            }
            4 => {
                remote.recovery.as_mut().unwrap().version += 1;
                Failure::RecoveryUnavailable
            }
            5 => {
                remote.recovery = None;
                Failure::RecoveryUnavailable
            }
            _ => {
                // The recovery HTTP operation itself changes the admitted scope.
                remote.change_on = Some(remote.calls + 3);
                Failure::ReviewRequired
            }
        };
        assert!(confirm(&mut store, &mut remote, value, entered).err() == Some(expected));
        let archive = store.transaction_with(Archive::load).unwrap();
        assert!(archive.presentation.unwrap().retained().is_ok());
        assert!(memory.slot(Slot::LibraryKey).unwrap() == original_key);
    }
}

#[test]
fn suffix_normalization_preserves_swift_graphemes_and_unicode_uppercase_expansions() {
    // Source-derived vectors from Swift CharacterProperties and the app's
    // verifier, not an execution of Swift on this Linux machine.
    for (entered, expected) in [
        ("aaßbbd0", true),
        (" AA-SS-BB-D0\n", true),
        ("\u{0301}aaßbbd0", true),
        ("aaßbbd0#\u{0301}", true),
        ("a\u{0301}assbbd0", false),
        ("aaßbbd0\u{0301}", false),
        ("aaßbbd0\u{fe0f}", false),
        ("aaßbbd0\u{20e3}", false),
        ("ＡＡＳＳＢＢＤ０", false),
    ] {
        assert!(disclosure::matches_suffix("AASS-BBD0", entered) == expected);
    }
}
#[test]
fn cancellation_during_remote_revalidation_keeps_the_kit_and_does_not_publish_verification() {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let (gate, value) = shown(&mut store, &mut remote);
    let entered = suffix(&value);
    let original = memory.slot(Slot::Bootstrap).unwrap();
    remote.cancel_on_recovery = Some(gate);
    assert!(
        confirm(&mut store, &mut remote, value, entered).err()
            == Some(Failure::Authentication(local_auth::Failure::Cancelled))
    );
    assert!(memory.slot(Slot::Bootstrap).unwrap() == original);
}
#[test]
fn failed_or_ambiguous_confirmation_write_resolves_after_restart_without_key_or_checkpoint_changes()
{
    for after in [false, true] {
        let memory = Memory::default();
        let (temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let checkpoint = checkpoint(&temp, &mut store, binding().checkpoint_scope());
        let original_key = memory.slot(Slot::LibraryKey).unwrap();
        let (_gate, value) = shown(&mut store, &mut remote);
        let entered = suffix(&value);
        {
            let mut state = memory.0.lock().unwrap();
            state.fail_write = Some((state.writes + 1, after));
        }
        assert!(
            confirm(&mut store, &mut remote, value, entered).err()
                == Some(Failure::Secret(secret_store::Failure::Unavailable))
        );
        drop(store);
        let mut store = Store::load(temp.path(), memory.clone()).unwrap();
        let expected = if after {
            KitStatus::VerifiedCurrent
        } else {
            KitStatus::AwaitingPresentation
        };
        assert!(initialize(&mut store, &mut remote).unwrap() == Outcome::Ready { kit: expected });
        if after {
            metadata_only(&memory);
        } else {
            let (_gate, value) = shown(&mut store, &mut remote);
            let entered = suffix(&value);
            assert!(confirm(&mut store, &mut remote, value, entered).is_ok());
            metadata_only(&memory);
        }
        assert!(memory.slot(Slot::LibraryKey).unwrap() == original_key);
        assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
        assert!(load(&mut store, &mut remote).unwrap().is_some());
    }
}
#[test]
fn verified_schema_one_migration_authenticates_the_old_kit_and_retires_it_before_key_publication() {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let original_key = memory.slot(Slot::LibraryKey).unwrap();
    let original = legacy(&mut store, &memory, true);
    assert!(load(&mut store, &mut remote).unwrap().is_some());
    assert!(memory.slot(Slot::Bootstrap).unwrap() != original);
    metadata_only(&memory);
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    assert!(prepare(&mut store, &mut remote).err() == Some(Failure::RecoveryUnavailable));
    assert!(memory.slot(Slot::LibraryKey).unwrap() == original_key && remote.posts == 1);
}
#[test]
fn unconfirmed_schema_one_migration_preserves_the_exact_kit_and_still_requires_fresh_authorization()
{
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let (_gate, before) = shown(&mut store, &mut remote);
    let payload = Zeroizing::new(before.qr_payload().unwrap().to_vec());
    legacy(&mut store, &memory, false);
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    let target = prepare(&mut store, &mut remote).unwrap();
    let (mut gate, permit) = permit(target);
    gate.cancel();
    assert!(
        reveal(&mut store, &mut remote, permit).err()
            == Some(Failure::Authentication(local_auth::Failure::Cancelled))
    );
    let (_gate, current) = shown(&mut store, &mut remote);
    assert!(current.qr_payload().unwrap() == payload.as_slice());
    let root = canonical::parse(&memory.slot(Slot::Bootstrap).unwrap()).unwrap();
    assert!(root.as_object().unwrap()["schema"].as_int().unwrap() == 2);
}
#[test]
fn migration_refuses_foreign_scope_or_authority_and_recovers_from_both_sides_of_a_failed_write() {
    for mode in 0..4 {
        let memory = Memory::default();
        let (temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let original_key = memory.slot(Slot::LibraryKey).unwrap();
        let original = legacy(&mut store, &memory, true);
        let expected = match mode {
            0 => {
                remote.pin.dataset = Binding::from_checkpoint([9; 32]);
                Failure::ReviewRequired
            }
            1 => {
                remote.public = Some([9; 32]);
                Failure::KeyConflict
            }
            _ => {
                let mut state = memory.0.lock().unwrap();
                state.fail_write = Some((state.writes + 1, mode == 3));
                Failure::Secret(secret_store::Failure::Unavailable)
            }
        };
        assert!(load(&mut store, &mut remote).err() == Some(expected));
        assert!(memory.slot(Slot::LibraryKey).unwrap() == original_key);
        if mode < 3 {
            assert!(memory.slot(Slot::Bootstrap).unwrap() == original);
        }
        if mode >= 2 {
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            assert!(load(&mut store, &mut remote).unwrap().is_some());
            metadata_only(&memory);
        }
    }
}
#[test]
fn verification_schema_rejects_secret_smuggling_bad_hashes_status_or_authority_without_overwriting_state()
 {
    for mode in 0..8 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let (_gate, value) = shown(&mut store, &mut remote);
        let entered = suffix(&value);
        confirm(&mut store, &mut remote, value, entered).unwrap();
        let original_key = memory.slot(Slot::LibraryKey).unwrap();
        let original = memory.slot(Slot::Bootstrap).unwrap();
        let mut value = canonical::parse(&original).unwrap();
        let Value::Object(root) = &mut value else {
            unreachable!()
        };
        if mode == 0 {
            root.insert("schema".into(), Value::Int(3));
        } else {
            let Value::Object(p) = root.get_mut("presentation").unwrap() else {
                unreachable!()
            };
            match mode {
                1 => {
                    p.insert("kit".into(), Value::Null);
                }
                2 => {
                    p.insert(
                        "ciphertextHash".into(),
                        Value::text(STANDARD.encode([0; 31])),
                    );
                }
                3 => {
                    p.insert("kitHash".into(), Value::text(STANDARD.encode([0; 33])));
                }
                4 => {
                    p.insert("status".into(), Value::text("awaiting_presentation"));
                }
                5 => {
                    p.insert("authority".into(), Value::text(STANDARD.encode([9; 32])));
                }
                6 => {
                    p.insert("version".into(), Value::Int(0));
                }
                _ => {
                    p.insert("kind".into(), Value::text("retained"));
                }
            }
        }
        let changed = value.encode().unwrap();
        store
            .transaction(|o| o.replace(Slot::Bootstrap, Some(&original), Some(&changed)))
            .unwrap();
        assert!(initialize(&mut store, &mut remote).is_err());
        assert!(
            memory.slot(Slot::Bootstrap).unwrap() == changed
                && memory.slot(Slot::LibraryKey).unwrap() == original_key
        );
    }
}

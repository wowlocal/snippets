use super::*;

#[test]
fn preparation_revocation_survives_an_unlock_and_rejects_unobserved_desktops() {
    for state in [SessionState::Locked, SessionState::Unavailable] {
        assert!(Preparation::new(SessionWitness::test(state, 1)).is_err());
    }
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let preparation = Preparation::new(witness.clone()).unwrap();
    preparation.validate().unwrap();
    let queued = preparation.clone();
    witness.test_observe(SessionState::Locked);
    witness.test_observe(SessionState::Unlocked);
    assert!(queued.validate().is_err());
    let fresh = Preparation::new(witness.clone()).unwrap();
    fresh.validate().unwrap();
    let worker = fresh.clone();
    fresh.cancel();
    assert_eq!(
        worker.validate(),
        Err(Failure::Authentication(local_auth::Failure::Cancelled))
    );
}

#[test]
fn preparation_deadlines_include_suspend_and_wall_time_without_refresh() {
    let preparation = Preparation::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
    for (monotonic, wall, valid) in [(119, 119, true), (120, 1, false), (1, 120, false)] {
        assert_eq!(
            preparation
                .validate_at(
                    preparation.started + Duration::from_secs(monotonic),
                    preparation.wall + Duration::from_secs(wall)
                )
                .is_ok(),
            valid
        );
    }
    assert!(
        preparation
            .validate_at(
                preparation.started,
                preparation.wall - Duration::from_secs(1)
            )
            .is_err()
    );
    assert!(
        preparation
            .validate_at(
                preparation.started - Duration::from_nanos(1),
                preparation.wall
            )
            .is_err()
    );
}

#[test]
fn current_vault_kdf_result_is_discarded_when_the_desktop_epoch_changes() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let document =
        crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    std::fs::create_dir(directory.path().join("Vault")).unwrap();
    let path = directory.path().join("Vault/vault.json");
    let bytes = document.encode().unwrap();
    crate::model::atomic_write(&path, &bytes).unwrap();
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let preparation = Preparation::new(witness.clone()).unwrap();
    let checks = std::cell::Cell::new(0);
    let result = unlock_current(
        directory.path(),
        &Credential {
            value: Zeroizing::new("Café public fixture".into()),
            recovery: false,
        },
        &|| {
            checks.set(checks.get() + 1);
            if checks.get() == 2 {
                witness.test_observe(SessionState::Locked);
                witness.test_observe(SessionState::Unlocked);
            }
            preparation.validate()
        },
    );
    assert!(matches!(
        result,
        Err(Failure::Authentication(local_auth::Failure::Expired))
    ));
    assert_eq!(checks.get(), 2);
    assert_eq!(std::fs::read(path).unwrap(), bytes);
    assert!(!directory.path().join("Sync").exists());
    assert!(!directory.path().join("Vault/apply.pending").exists());
}

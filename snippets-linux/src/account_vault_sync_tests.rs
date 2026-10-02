//! Public independent wraps, temporary roots and fictional desktop observation.
use super::*;
use crate::{
    cloud::Binding,
    desktop::{SessionState, SessionWitness},
};
use std::fs;
fn scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x33; 32]),
        dataset: Binding::from_checkpoint([0x44; 32]),
    }
}
fn setup() -> (tempfile::TempDir, Document, SessionWitness, Request) {
    let temporary = tempfile::tempdir().unwrap();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let document = Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    let library = crate::model::Library::prepare(temporary.path().into()).unwrap();
    fs::create_dir(library.root.join("Vault")).unwrap();
    crate::model::atomic_write(
        &library.root.join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let request = Request::capture(
        temporary.path(),
        &scope(),
        1,
        Authorization::new(witness.clone()).unwrap(),
    )
    .unwrap();
    (temporary, document, witness, request)
}
fn observed<T>(witness: &SessionWitness, operation: impl FnOnce() -> T) -> T {
    struct Stop<'a>(&'a AtomicBool);
    impl Drop for Stop<'_> {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }
    let stop = AtomicBool::new(false);
    std::thread::scope(|scope| {
        scope.spawn(|| {
            while !stop.load(Ordering::Acquire) {
                witness.test_observe(SessionState::Unlocked);
                std::thread::sleep(Duration::from_millis(25));
            }
        });
        let _stop = Stop(&stop);
        operation()
    })
}
fn authenticate(request: Request, witness: &SessionWitness) -> Result<Authenticated> {
    let token = request.presentation().0;
    observed(witness, || {
        request.authenticate(token, Zeroizing::new("Café public fixture".into()), false)
    })
}
#[test]
fn independent_passphrase_and_recovery_authenticate_one_bound_cycle_without_writes() {
    for recovery in [false, true] {
        let (temporary, document, witness, request) = setup();
        let (token, methods) = request.presentation();
        assert!(methods.passphrase && methods.recovery);
        let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
        let credential = if recovery {
            crate::crypto::format_recovery(&[0x66; 16])
        } else {
            Zeroizing::new("Café public fixture".into())
        };
        let authenticated = observed(&witness, || {
            request.authenticate(token, credential, recovery)
        })
        .unwrap();
        authenticated.bind(&scope(), 1).unwrap();
        let keys = authenticated.keys().unwrap();
        let view = crate::projection::current(
            &[],
            Some(&document),
            "11111111",
            &std::collections::BTreeMap::new(),
            &std::collections::BTreeMap::new(),
        )
        .unwrap();
        crate::materializer::authenticate(view.values().next().unwrap(), &keys, true).unwrap();
        assert_eq!(
            fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
            before
        );
        assert!(
            !temporary.path().join("Sync").exists()
                && !temporary.path().join("device.json").exists()
        );
        let mut wrong = scope();
        wrong.dataset = Binding::from_checkpoint([0x55; 32]);
        assert!(authenticated.bind(&wrong, 1).is_err() && authenticated.bind(&scope(), 2).is_err());
    }
}
#[test]
fn exact_source_is_required_before_credentials_and_before_data_plane_binding() {
    for after_auth in [false, true] {
        let (temporary, _, witness, request) = setup();
        let path = temporary.path().join("Vault/vault.json");
        let before = fs::read(&path).unwrap();
        if after_auth {
            let authenticated = authenticate(request, &witness).unwrap();
            crate::model::atomic_write(&path, &before).unwrap();
            assert!(authenticated.bind(&scope(), 1).is_err());
        } else {
            crate::model::atomic_write(&path, &before).unwrap();
            assert!(authenticate(request, &witness).is_err());
        }
        assert_eq!(fs::read(path).unwrap(), before);
        assert!(!temporary.path().join("Sync").exists());
    }
}
#[test]
fn wrong_tokens_credentials_and_bounds_never_write_or_fall_back_to_an_editor_session() {
    for invalid in 0..4 {
        let (temporary, _, witness, request) = setup();
        let (mut token, _) = request.presentation();
        let credential = match invalid {
            0 => {
                token = uuid::Uuid::new_v4();
                "Café public fixture".into()
            }
            1 => "Public wrong passphrase".into(),
            2 => String::new(),
            3 => "X".repeat(4097),
            _ => unreachable!(),
        };
        let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
        assert!(
            observed(&witness, || request.authenticate(
                token,
                Zeroizing::new(credential),
                false
            ))
            .is_err()
        );
        assert_eq!(
            fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
            before
        );
        assert!(!temporary.path().join("Sync").exists());
    }
}
#[test]
fn cancellation_and_changed_desktop_epoch_revoke_prepared_keys() {
    for cancel in [false, true] {
        let (_temporary, _, witness, request) = setup();
        let authorization = request.authorization.clone();
        let authenticated = authenticate(request, &witness).unwrap();
        if cancel {
            authorization.cancel();
        } else {
            witness.test_observe(SessionState::Locked);
            witness.test_observe(SessionState::Unlocked);
        }
        assert!(authenticated.validate().is_err() && authenticated.keys().is_err());
    }
}
#[test]
fn own_record_changes_are_allowed_after_binding_but_changed_wraps_remain_incompatible() {
    let (_temporary, document, witness, request) = setup();
    let authenticated = authenticate(request, &witness).unwrap();
    authenticated.bind(&scope(), 1).unwrap();
    let keys = authenticated.keys().unwrap();
    let mut edited = document.clone();
    edited.records[0].metadata.name = "Public changed record".into();
    assert!(keys.matches(&edited));
    edited.wrap_pass = None;
    assert!(!keys.matches(&edited));
}

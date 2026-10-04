use super::*;
use crate::{
    cloud::{Binding, ServerURL},
    key_store::KeyBinding,
};
use uuid::Uuid;
fn target(purpose: Purpose) -> Target {
    Target::new(
        KeyBinding::new(
            ServerURL::parse("https://sync.example").unwrap(),
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            (
                Binding::from_checkpoint([3; 32]),
                Binding::from_checkpoint([4; 32]),
            ),
            1,
        )
        .unwrap(),
        purpose,
        1,
        [5; 32],
    )
    .unwrap()
}
fn ready() -> (Gate, SessionWitness) {
    let mut gate = Gate::new();
    gate.set_foreground(true);
    (gate, SessionWitness::test(SessionState::Unlocked, 7))
}
fn authenticate(request: Request) -> Result<Authenticated> {
    authenticate_with(
        request,
        Zeroizing::new(b"Public fictional password".to_vec()),
        |_, password| {
            assert!(password == b"Public fictional password");
            Ok(())
        },
    )
}
#[test]
fn authorization_is_one_use_bound_to_exact_purpose_scope_generation_and_digest() {
    for mutation in 0..5 {
        let (mut gate, witness) = ready();
        let original = target(Purpose::RevealRecovery);
        let request = gate.begin(original.clone(), witness).unwrap();
        let authenticated = authenticate(request).unwrap();
        let permit = gate.accept(authenticated).unwrap();
        let mut changed = original.clone();
        match mutation {
            0 => changed.purpose = Purpose::ReplaceRecovery,
            1 => changed.generation += 1,
            2 => changed.digest[0] ^= 1,
            3 => changed.binding = target(Purpose::ApprovePairing).binding,
            _ => (),
        }
        if mutation == 3 {
            changed.binding = Some(
                KeyBinding::new(
                    ServerURL::parse("https://other.example").unwrap(),
                    Uuid::from_u128(1),
                    Uuid::from_u128(2),
                    (
                        Binding::from_checkpoint([3; 32]),
                        Binding::from_checkpoint([4; 32]),
                    ),
                    1,
                )
                .unwrap(),
            );
        }
        if mutation < 4 {
            assert!(permit.consume(&changed).err() == Some(Failure::WrongTarget));
        } else {
            let lease = permit.consume(&original).unwrap();
            assert!(lease.check().is_ok());
            gate.cancel();
            assert!(lease.check().err() == Some(Failure::Cancelled));
        }
        assert!(gate.pending.is_none());
    }
}
#[test]
fn account_key_disclosure_is_account_scoped_and_never_a_library_purpose() {
    assert!(target(Purpose::RevealRecovery).binding.is_some());
    let library = target(Purpose::RevealRecovery).binding.unwrap();
    assert!(
        Target::new(library, Purpose::RevealAccountKey, 1, [5; 32]).err()
            == Some(Failure::InvalidState)
    );
    assert!(Target::account_key(0, [5; 32]).err() == Some(Failure::InvalidState));
    let original = Target::account_key(1, [5; 32]).unwrap();
    assert!(original.purpose() == Purpose::RevealAccountKey && original.binding.is_none());
    for changed in [
        Target::account_key(2, [5; 32]).unwrap(),
        Target::account_key(1, [6; 32]).unwrap(),
        target(Purpose::RevealRecovery),
    ] {
        let (mut gate, witness) = ready();
        let request = gate.begin(original.clone(), witness).unwrap();
        let permit = gate.accept(authenticate(request).unwrap()).unwrap();
        assert!(permit.consume(&changed).err() == Some(Failure::WrongTarget));
    }
    let (mut gate, witness) = ready();
    let request = gate.begin(original.clone(), witness).unwrap();
    let permit = gate.accept(authenticate(request).unwrap()).unwrap();
    let lease = permit.consume(&original).unwrap();
    gate.set_foreground(false);
    assert!(lease.check().err() == Some(Failure::Cancelled));
}
#[test]
fn locked_missing_stale_and_lock_cycles_cannot_authorize_a_worker() {
    for state in [SessionState::Locked, SessionState::Unavailable] {
        let (mut gate, _) = ready();
        assert!(
            gate.begin(
                target(Purpose::RevealRecovery),
                SessionWitness::test(state, 1)
            )
            .err()
                == Some(Failure::DesktopUnavailable)
        );
    }
    let (mut gate, witness) = ready();
    let request = gate
        .begin(target(Purpose::RevealRecovery), witness.clone())
        .unwrap();
    witness.test_observe(SessionState::Locked);
    witness.test_observe(SessionState::Unlocked);
    assert!(authenticate(request).err() == Some(Failure::DesktopUnavailable));
}
#[test]
fn cancellation_backgrounding_new_request_and_owner_drop_revoke_pending_and_issued_authority() {
    for action in 0..4 {
        let (mut gate, witness) = ready();
        let expected = target(Purpose::RevealRecovery);
        let request = gate.begin(expected.clone(), witness.clone()).unwrap();
        let permit = gate.accept(authenticate(request).unwrap()).unwrap();
        match action {
            0 => gate.cancel(),
            1 => gate.set_foreground(false),
            2 => {
                gate.begin(expected.clone(), witness).unwrap();
            }
            _ => drop(gate),
        }
        assert!(permit.consume(&expected).err() == Some(Failure::Cancelled));
    }
}
#[test]
fn late_worker_result_cannot_publish_after_cancel_or_replacement() {
    for replace in [false, true] {
        let (mut gate, witness) = ready();
        let request = gate
            .begin(target(Purpose::ApprovePairing), witness.clone())
            .unwrap();
        let authenticated = authenticate(request).unwrap();
        if replace {
            gate.begin(target(Purpose::ReplaceRecovery), witness)
                .unwrap();
        } else {
            gate.cancel();
        }
        assert!(gate.accept(authenticated).err() == Some(Failure::Cancelled));
    }
    let (mut gate, witness) = ready();
    let request = gate
        .begin(target(Purpose::ApprovePairing), witness)
        .unwrap();
    let authenticated = authenticate(request).unwrap();
    let (mut other, _) = ready();
    assert!(other.accept(authenticated).err() == Some(Failure::Cancelled));
}
#[test]
fn either_expiry_clock_including_suspend_closes_authority_and_overflow_fails_closed() {
    let (mut gate, witness) = ready();
    let request = gate
        .begin(target(Purpose::RevealRecovery), witness)
        .unwrap();
    assert!(
        request
            .context
            .check_at(
                request.context.wall,
                request.context.uptime - Duration::from_secs(1)
            )
            .err()
            == Some(Failure::Expired)
    );
    assert!(
        request
            .context
            .check_at(
                request.context.wall - Duration::from_secs(3600),
                request.context.uptime
            )
            .err()
            == Some(Failure::Expired)
    );
    gate.epoch.store(u64::MAX - 1, Ordering::Release);
    assert!(
        gate.begin(
            target(Purpose::RevealRecovery),
            SessionWitness::test(SessionState::Unlocked, 1)
        )
        .err()
            == Some(Failure::InvalidState)
    );
}
#[test]
fn invalid_credentials_and_denied_account_proofs_never_produce_authority() {
    for password in [Vec::new(), vec![1; 4097], vec![1, 0, 2]] {
        let (mut gate, witness) = ready();
        let request = gate
            .begin(target(Purpose::RevealRecovery), witness)
            .unwrap();
        assert!(
            authenticate_with(request, Zeroizing::new(password), |_, _| panic!(
                "backend must not receive an invalid password"
            ))
            .err()
                == Some(Failure::InvalidCredential)
        );
    }
    for failure in [
        Failure::Denied,
        Failure::AccountRestricted,
        Failure::WrongIdentity,
        Failure::UnsupportedConversation,
    ] {
        let (mut gate, witness) = ready();
        let request = gate
            .begin(target(Purpose::RevealRecovery), witness)
            .unwrap();
        assert!(
            authenticate_with(request, Zeroizing::new(b"Public".to_vec()), |_, _| Err(
                failure
            ))
            .err()
                == Some(failure)
        );
    }
}

#[cfg(feature = "local-auth")]
#[path = "local_auth_native_tests.rs"]
mod native;

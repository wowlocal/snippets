use super::*;
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Instant,
};
struct Fixture {
    temp: tempfile::TempDir,
    helper: PathBuf,
    module: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let helper = temp.path().join("owner-fixture");
        let module = temp.path().join("pam-fixture.so");
        assert!(
            Command::new("cc")
                .args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Werror"])
                .arg(root.join("tests/fixtures/pam-module.c"))
                .arg("-o")
                .arg(&module)
                .arg("-lpam")
                .output()
                .unwrap()
                .status
                .success()
        );
        assert!(
            Command::new("cc")
                .args(["-Wall", "-Wextra", "-Werror"])
                .arg(format!(
                    "-DSNIP_OWNER_FIXTURE_MAIN=\"{}\"",
                    temp.path().display()
                ))
                .arg(root.join("src/owner_auth.c"))
                .arg("-o")
                .arg(&helper)
                .arg("-lpam")
                .output()
                .unwrap()
                .status
                .success()
        );
        Self {
            temp,
            helper,
            module,
        }
    }
    fn policy(&self, auth: &str, account: &str) {
        fs::write(
            self.temp.path().join("system-auth"),
            format!(
                "auth required {} {}\naccount required {} {}\n",
                self.module.display(),
                auth,
                self.module.display(),
                account
            ),
        )
        .unwrap();
    }
}
#[test]
fn actual_pam_with_private_policy_requires_one_password_valid_account_and_exact_current_identity() {
    let fixture = Fixture::new();
    let native = Native::fixture(fixture.helper.clone()).unwrap();
    for (auth, account, password, expected) in [
        ("password", "valid", "Public fictional password", None),
        (
            "password",
            "valid",
            "Public incorrect password",
            Some(Failure::Denied),
        ),
        (
            "password",
            "expired",
            "Public fictional password",
            Some(Failure::AccountRestricted),
        ),
        (
            "password",
            "change",
            "Public fictional password",
            Some(Failure::AccountRestricted),
        ),
        (
            "password",
            "identity",
            "Public fictional password",
            Some(Failure::WrongIdentity),
        ),
        (
            "password",
            "conversation",
            "Public fictional password",
            Some(Failure::UnsupportedConversation),
        ),
        (
            "cached",
            "valid",
            "Public fictional password",
            Some(Failure::UnsupportedConversation),
        ),
        (
            "echo",
            "valid",
            "Public fictional password",
            Some(Failure::UnsupportedConversation),
        ),
        (
            "second",
            "valid",
            "Public fictional password",
            Some(Failure::UnsupportedConversation),
        ),
    ] {
        fixture.policy(auth, account);
        let (mut gate, witness) = ready();
        let original = target(Purpose::RevealRecovery);
        let request = gate.begin(original.clone(), witness).unwrap();
        let result = native.authenticate(request, Zeroizing::new(password.as_bytes().to_vec()));
        if let Some(expected) = expected {
            assert!(result.err() == Some(expected));
        } else {
            // Only the closed failure vocabulary can appear in fixture output;
            // never print PAM text, the password, identity or child arguments.
            let authenticated =
                result.unwrap_or_else(|failure| panic!("private PAM fixture returned {failure:?}"));
            let permit = gate.accept(authenticated).unwrap();
            assert!(permit.consume(&original).is_ok());
        }
    }
}
#[test]
fn native_worker_timeout_and_cancellation_kill_and_reap_only_the_owned_fixture_process() {
    let fixture = Fixture::new();
    fixture.policy("sleep", "valid");
    let (mut gate, witness) = ready();
    let request = gate
        .begin(target(Purpose::ApprovePairing), witness)
        .unwrap();
    let started = Instant::now();
    let native = Native::fixture(fixture.helper.clone()).unwrap();
    assert!(
        native
            .fixture_authenticate_limit(
                request,
                Zeroizing::new(b"Public fictional password".to_vec()),
                Duration::from_millis(50)
            )
            .err()
            == Some(Failure::Timeout)
    );
    assert!(started.elapsed() < Duration::from_secs(1));
    let request = gate
        .begin(
            target(Purpose::ApprovePairing),
            SessionWitness::test(SessionState::Unlocked, 1),
        )
        .unwrap();
    let worker = thread::spawn(move || {
        native.authenticate(
            request,
            Zeroizing::new(b"Public fictional password".to_vec()),
        )
    });
    thread::sleep(Duration::from_millis(50));
    gate.cancel();
    assert!(worker.join().unwrap().err() == Some(Failure::Cancelled));
}
#[test]
fn native_helper_must_be_a_private_regular_executable_and_emit_exactly_one_closed_status_byte() {
    let temp = tempfile::tempdir().unwrap();
    let helper = temp.path().join("public-protocol-fixture");
    for output in ["\\007", "\\000\\000"] {
        fs::write(
            &helper,
            format!("#!/bin/sh\ncat >/dev/null\nprintf '{output}'\n"),
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        let native = Native::fixture(helper.clone()).unwrap();
        let (mut gate, witness) = ready();
        let request = gate
            .begin(target(Purpose::RevealRecovery), witness)
            .unwrap();
        assert!(
            native
                .authenticate(
                    request,
                    Zeroizing::new(b"Public fictional password".to_vec())
                )
                .err()
                == Some(Failure::Protocol)
        );
    }
    for mode in [0o777, 0o4700, 0o2700, 0o600] {
        fs::set_permissions(&helper, fs::Permissions::from_mode(mode)).unwrap();
        assert!(Native::fixture(helper.clone()).err() == Some(Failure::Unavailable));
    }
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
    let native = Native::fixture(helper.clone()).unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o777)).unwrap();
    let (mut gate, witness) = ready();
    let request = gate
        .begin(target(Purpose::RevealRecovery), witness)
        .unwrap();
    assert!(
        native
            .authenticate(
                request,
                Zeroizing::new(b"Public fictional password".to_vec())
            )
            .err()
            == Some(Failure::Unavailable)
    );
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
    let link = temp.path().join("linked-helper");
    symlink(&helper, &link).unwrap();
    assert!(Native::fixture(link).err() == Some(Failure::Unavailable));
}

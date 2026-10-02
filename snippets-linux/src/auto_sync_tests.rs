use super::*;
use crate::{
    cloud::ServerURL,
    secret_store::{Store, tests::Memory},
};
use std::{fs, os::unix::fs::symlink};

fn deployment() -> Deployment {
    Deployment::from_discovery(
        ServerURL::parse("https://sync.example").unwrap(),
        Uuid::from_u128(1),
    )
}
fn binding(space: u128, member: u8, dataset: u8, epoch: u64) -> KeyBinding {
    KeyBinding::new(
        deployment().server().clone(),
        Uuid::from_u128(1),
        Uuid::from_u128(space),
        (
            Binding::from_checkpoint([member; 32]),
            Binding::from_checkpoint([dataset; 32]),
        ),
        epoch,
    )
    .unwrap()
}
fn target() -> Target {
    Target::new(binding(2, 3, 4, 1), &deployment(), "fictional-account").unwrap()
}
fn enable(root: &Path, store: &mut Store<Memory>, target: &Target) -> Preference {
    store
        .transaction_with::<_, Failure>(|owner| target.save(owner))
        .unwrap();
    Preference::on(root, target).unwrap();
    Preference::read(root).unwrap()
}
#[test]
fn fresh_install_is_off_and_read_has_no_side_effects() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("absent");
    assert!(!Preference::read(&root).unwrap().enabled());
    assert!(!root.exists());
    let control = Control::new();
    assert!(matches!(
        control.ticket(&root, Preference { consent: None }),
        Err(Failure::Cancelled)
    ));
    assert!(!root.exists());
}
#[test]
fn consent_is_private_nonce_and_target_is_only_in_secret_service() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), Memory::default()).unwrap();
    let target = target();
    let pref = enable(temp.path(), &mut store, &target);
    let loaded = store
        .transaction_with::<_, Failure>(|owner| Target::load(owner, pref))
        .unwrap();
    loaded
        .validate_account(&deployment(), "fictional-account")
        .unwrap();
    loaded.validate_binding(&binding(2, 3, 4, 1)).unwrap();
    let bytes = fs::read(temp.path().join(PREFERENCE)).unwrap();
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v.as_object().unwrap().len(), 3);
    assert_eq!(
        fs::metadata(temp.path().join(PREFERENCE))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    for file in fs::read_dir(temp.path()).unwrap() {
        let bytes = fs::read(file.unwrap().path()).unwrap();
        for private in ["fictional-account", "sync.example", "membership", "dataset"] {
            assert!(
                !bytes
                    .windows(private.len())
                    .any(|part| part == private.as_bytes())
            );
        }
    }
    assert!(!temp.path().join("Sync").exists());
    assert!(!temp.path().join("device.json").exists());
}
#[test]
fn every_account_library_and_epoch_change_requires_new_consent() {
    let t = target();
    assert_eq!(
        t.validate_account(&deployment(), "another-account"),
        Err(Failure::ScopeChanged)
    );
    for d in [
        Deployment::from_discovery(deployment().server().clone(), Uuid::from_u128(9)),
        Deployment::from_discovery(
            ServerURL::parse("https://other.example").unwrap(),
            Uuid::from_u128(1),
        ),
    ] {
        assert_eq!(
            t.validate_account(&d, "fictional-account"),
            Err(Failure::ScopeChanged)
        );
    }
    for b in [
        binding(9, 3, 4, 1),
        binding(2, 9, 4, 1),
        binding(2, 3, 9, 1),
        binding(2, 3, 4, 9),
    ] {
        assert_eq!(t.validate_binding(&b), Err(Failure::ScopeChanged));
    }
}
#[test]
fn stale_missing_and_ambiguous_target_never_admit_a_ticket() {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let first = target();
    Preference::on(temp.path(), &first).unwrap();
    let pref = Preference::read(temp.path()).unwrap();
    assert!(matches!(
        store.transaction_with::<_, Failure>(|owner| Target::load(owner, pref)),
        Err(Failure::ScopeChanged)
    ));
    enable(temp.path(), &mut store, &first);
    let second = target();
    store
        .transaction_with::<_, Failure>(|owner| second.save(owner))
        .unwrap();
    assert!(matches!(
        store.transaction_with::<_, Failure>(|owner| Target::load(owner, pref)),
        Err(Failure::ScopeChanged)
    ));
    memory.0.lock().unwrap().fail_write_after = true;
    assert!(matches!(
        store.transaction_with::<_, Failure>(|owner| first.save(owner)),
        Err(Failure::Secret(_))
    ));
    assert!(Preference::read(temp.path()).unwrap() == pref);
}
#[test]
fn interrupt_disable_and_other_process_preference_revoke_active_tickets() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), Memory::default()).unwrap();
    let pref = enable(temp.path(), &mut store, &target());
    let control = Control::new();
    let first = control.ticket(temp.path(), pref).unwrap();
    control.interrupt();
    assert_eq!(first.validate(), Err(Failure::Cancelled));
    let second = control.ticket(temp.path(), pref).unwrap();
    control.pause();
    assert_eq!(second.validate(), Err(Failure::Cancelled));
    control.resume();
    assert_eq!(second.validate(), Err(Failure::Cancelled));
    let third = control.ticket(temp.path(), pref).unwrap();
    Preference::off(temp.path()).unwrap();
    assert_eq!(third.validate(), Err(Failure::Cancelled));
    let pref = enable(temp.path(), &mut store, &target());
    let last = control.ticket(temp.path(), pref).unwrap();
    control.prepare_quit();
    control.resume();
    assert_eq!(last.validate(), Err(Failure::Cancelled));
    assert!(control.quitting());
    control.cancel_quit();
    control.resume();
    assert_eq!(last.validate(), Err(Failure::Cancelled));
    control
        .ticket(temp.path(), pref)
        .unwrap()
        .validate()
        .unwrap();
}
#[test]
fn disable_works_with_recovery_fence_and_locked_secret_service() {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    enable(temp.path(), &mut store, &target());
    fs::create_dir(temp.path().join("Backups")).unwrap();
    let fence = temp.path().join("Backups/restore.pending");
    fs::write(&fence, b"fictional opaque recovery fence").unwrap();
    memory.0.lock().unwrap().fail_read = Some(crate::secret_store::Failure::Locked);
    Preference::off(temp.path()).unwrap();
    assert!(!Preference::read(temp.path()).unwrap().enabled());
    assert_eq!(fs::read(fence).unwrap(), b"fictional opaque recovery fence");
    assert!(!temp.path().join("snippets.json").exists());
}
#[test]
fn malformed_world_readable_and_linked_preferences_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join(PREFERENCE);
    for content in [
        r#"{"schemaVersion":2,"automatic":false,"consent":null}"#,
        r#"{"schemaVersion":1,"automatic":true,"consent":null}"#,
        r#"{"schemaVersion":1,"automatic":false,"consent":null,"account":"x"}"#,
        r#"{"schemaVersion":1,"automatic":true,"consent":"00000000-0000-0000-0000-000000000000"}"#,
    ] {
        model::atomic_write(&path, content.as_bytes()).unwrap();
        assert!(matches!(
            Preference::read(temp.path()),
            Err(Failure::InvalidState)
        ));
    }
    Preference::off(temp.path()).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(matches!(
        Preference::read(temp.path()),
        Err(Failure::Storage)
    ));
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let link = temp.path().join("other");
    fs::hard_link(&path, &link).unwrap();
    assert!(matches!(
        Preference::read(temp.path()),
        Err(Failure::Storage)
    ));
    fs::remove_file(&path).unwrap();
    symlink(&link, &path).unwrap();
    assert!(matches!(
        Preference::read(temp.path()),
        Err(Failure::Storage)
    ));
}
#[test]
fn bounded_schedule_coalesces_edits_serializes_cycles_and_backs_off() {
    let s = Duration::from_secs;
    let mut schedule = Schedule::new(s(0));
    assert!(schedule.begin(s(0)));
    assert!(!schedule.begin(s(1)));
    schedule.finish(Outcome::Current, s(1));
    schedule.wake(Wake::LocalEdit, s(2));
    schedule.wake(Wake::LocalEdit, s(3));
    assert!(!schedule.begin(s(3)));
    assert!(schedule.begin(s(4)));
    schedule.finish(Outcome::Retry, s(4));
    schedule.wake(Wake::Foreground, s(5));
    schedule.wake(Wake::LocalEdit, s(5));
    assert!(!schedule.begin(s(8)));
    assert!(schedule.begin(s(9)));
    let mut now = s(9);
    for delay in [10, 20, 40, 80, 160, 300, 300] {
        schedule.finish(Outcome::Retry, now);
        assert!(!schedule.begin(now + s(delay - 1)));
        now += s(delay);
        assert!(schedule.begin(now));
    }
    schedule.finish(Outcome::MoreWork, now);
    assert!(!schedule.begin(now + s(1)));
    assert!(schedule.begin(now + s(2)));
    schedule.finish(Outcome::Attention, now + s(2));
    schedule.wake(Wake::Foreground, now + s(3));
    schedule.wake(Wake::LocalEdit, now + s(3));
    assert!(schedule.halted());
    assert!(!schedule.begin(now + s(3600)));
}
#[test]
fn server_retry_delay_cannot_be_shortened_by_local_wakes() {
    let s = Duration::from_secs;
    let mut schedule = Schedule::new(s(0));
    assert!(schedule.begin(s(0)));
    schedule.finish(Outcome::Retry, s(1));
    schedule.defer(s(1), s(3600));
    schedule.wake(Wake::Foreground, s(2));
    assert!(!schedule.begin(s(3600)));
    assert!(schedule.begin(s(3601)));
}

use super::*;
use std::sync::mpsc::{Receiver, Sender};
struct Fake(Receiver<Action>);
impl Backend for Fake {
    fn next(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<Option<(Action, Duration)>> {
        guard()?;
        Ok(self
            .0
            .recv_timeout(Duration::from_millis(10))
            .ok()
            .map(|a| (a, Duration::ZERO)))
    }
}
fn wait(condition: impl Fn() -> bool) {
    let start = std::time::Instant::now();
    while !condition() {
        assert!(start.elapsed() < Duration::from_secs(2));
        thread::sleep(Duration::from_millis(2));
    }
}
fn fixture(root: &Path, witness: SessionWitness) -> (Handle, Sender<Action>) {
    Preference::write(root, true).unwrap();
    let (sender, receiver) = mpsc::channel();
    let handle = Handle::start_with(root.to_owned(), witness, None, move |guard| {
        guard()?;
        Ok(Box::new(Fake(receiver)))
    })
    .unwrap();
    wait(|| handle.status() == Status::Registered);
    (handle, sender)
}
#[test]
fn disabled_and_malformed_consent_never_constructs_a_backend() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("Public absent");
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    assert!(
        Handle::start_with(root.clone(), witness.clone(), None, |_| panic!(
            "must not connect"
        ))
        .is_err()
    );
    assert!(!root.exists());
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join(FILE), b"Public malformed").unwrap();
    assert!(Handle::start_with(root, witness, None, |_| panic!("must not connect")).is_err());
}
#[test]
fn queued_events_expire_and_lock_unlock_revokes_the_old_epoch() {
    let witness = SessionWitness::test(SessionState::Unlocked, 4);
    let event = Event::new(Action::Open, Duration::ZERO, witness.clone()).unwrap();
    assert!(event.valid());
    witness.test_observe(SessionState::Locked);
    assert!(!event.valid());
    witness.test_observe(SessionState::Unlocked);
    assert!(!event.valid());
    assert!(Event::new(Action::Capture, Duration::from_secs(2), witness.clone()).is_none());
    let mut fresh = Event::new(Action::Capture, Duration::ZERO, witness.clone()).unwrap();
    fresh.deadline = crate::clock::uptime().unwrap();
    assert!(!fresh.valid());
    witness.test_observe(SessionState::Unavailable);
    assert!(Event::new(Action::Open, Duration::ZERO, witness).is_none());
}
#[test]
fn explicit_stop_immediately_fences_queued_calls_and_finishes_the_worker() {
    let temporary = tempfile::tempdir().unwrap();
    let (handle, sender) = fixture(
        temporary.path(),
        SessionWitness::test(SessionState::Unlocked, 1),
    );
    sender.send(Action::Open).unwrap();
    wait(|| !handle.events.try_iter().collect::<Vec<_>>().is_empty());
    sender.send(Action::Capture).unwrap();
    handle.stop();
    assert!(handle.next().is_none());
    wait(|| handle.is_finished());
    assert!(handle.status() == Status::Off);
}
#[test]
fn persisted_revocation_stops_registration_without_automatic_reconnect() {
    let temporary = tempfile::tempdir().unwrap();
    let (handle, _sender) = fixture(
        temporary.path(),
        SessionWitness::test(SessionState::Unlocked, 1),
    );
    Preference::write(temporary.path(), false).unwrap();
    wait(|| handle.is_finished());
    assert!(handle.next().is_none());
    assert!(handle.status() == Status::Off);
}
#[test]
fn stalled_ui_has_a_fixed_queue_bound_and_refuses_expired_public_events() {
    let temporary = tempfile::tempdir().unwrap();
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let (handle, sender) = fixture(temporary.path(), witness.clone());
    for _ in 0..50 {
        sender.send(Action::Open).unwrap();
    }
    thread::sleep(Duration::from_millis(50));
    let events = handle.events.try_iter().collect::<Vec<_>>();
    assert_eq!(events.len(), 3);
    witness.test_observe(SessionState::Locked);
    assert!(events.iter().all(|e| !e.valid()));
    handle.stop();
    wait(|| handle.is_finished());
}

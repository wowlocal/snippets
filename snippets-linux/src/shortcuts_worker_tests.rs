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
    let delivered = handle.events.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(delivered.valid());
    sender.send(Action::Capture).unwrap();
    handle.stop();
    assert!(!delivered.valid());
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

enum RecoveryMessage {
    Action,
    Disappeared,
    Closed,
}
struct Recovering {
    input: Receiver<RecoveryMessage>,
    recoveries: Arc<std::sync::atomic::AtomicUsize>,
    disappeared: bool,
}
impl Backend for Recovering {
    fn next(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<Option<(Action, Duration)>> {
        guard()?;
        match self.input.recv_timeout(Duration::from_millis(10)) {
            Ok(RecoveryMessage::Action) => Ok(Some((Action::Open, Duration::ZERO))),
            Ok(RecoveryMessage::Disappeared) => {
                self.disappeared = true;
                Err(UNAVAILABLE)
            }
            Ok(RecoveryMessage::Closed) => Err(UNAVAILABLE),
            Err(_) => Ok(None),
        }
    }
    fn can_reconnect(&self) -> bool {
        self.disappeared
    }
    fn reconnect(mut self: Box<Self>, guard: &dyn Fn() -> Result<()>) -> Result<Box<dyn Backend>> {
        guard()?;
        assert!(self.disappeared);
        self.disappeared = false;
        self.recoveries.fetch_add(1, Ordering::AcqRel);
        Ok(self)
    }
}
#[test]
fn service_recovery_revokes_queued_events_and_explicit_close_never_reconnects() {
    let temporary = tempfile::tempdir().unwrap();
    Preference::write(temporary.path(), true).unwrap();
    let (sender, input) = mpsc::channel();
    let recoveries = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let observed = recoveries.clone();
    let handle = Handle::start_with(
        temporary.path().to_owned(),
        SessionWitness::test(SessionState::Unlocked, 1),
        None,
        move |_| {
            Ok(Box::new(Recovering {
                input,
                recoveries,
                disappeared: false,
            }))
        },
    )
    .unwrap();
    let receive = || {
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(event) = handle.next() {
                break event;
            }
            assert!(std::time::Instant::now() < deadline);
            thread::sleep(Duration::from_millis(2));
        }
    };
    sender.send(RecoveryMessage::Action).unwrap();
    let old = receive();
    assert!(old.valid());
    sender.send(RecoveryMessage::Disappeared).unwrap();
    wait(|| observed.load(Ordering::Acquire) == 1 && handle.status() == Status::Registered);
    assert!(!old.valid());
    sender.send(RecoveryMessage::Action).unwrap();
    let fresh = receive();
    assert!(fresh.valid());
    sender.send(RecoveryMessage::Closed).unwrap();
    wait(|| handle.is_finished());
    assert!(!fresh.valid());
    assert_eq!(observed.load(Ordering::Acquire), 1);
    assert!(handle.status() == Status::Unavailable);
}

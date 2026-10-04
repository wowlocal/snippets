use super::*;

fn storage(failure: Option<Failure>) -> Event {
    Event::Storage {
        area: Area::Library,
        operation: StorageOperation::Save,
        outcome: if failure.is_some() {
            Outcome::Failed
        } else {
            Outcome::Succeeded
        },
        duration_ms: Milliseconds::new(Duration::MAX),
        count: Count::new(usize::MAX),
        failure,
    }
}
#[test]
fn diagnostic_values_bound_counts_time_and_discard_error_text() {
    let error = std::io::Error::other("PRIVATE body /home/private/device-id token ciphertext");
    let event = storage(Some(Failure::from_io(&error)));
    let value = serde_json::to_value(event).unwrap();
    assert_eq!(value["fields"]["count"], 1_000_000);
    assert_eq!(value["fields"]["duration_ms"], 86_400_000);
    assert_eq!(
        value["fields"]["failure"],
        serde_json::json!({"family":"posix","code":0})
    );
    let encoded = value.to_string();
    for forbidden in [
        "PRIVATE",
        "private",
        "device-id",
        "ciphertext",
        "token",
        "body",
        "message",
        "path",
    ] {
        assert!(!encoded.contains(forbidden));
    }
    assert_eq!(event.category(), "persistence");
    assert_eq!(event.level(), "error");
    assert!(event.synchronous());
}
#[test]
fn event_deserialization_refuses_escape_hatches_and_invalid_bounds() {
    let good = serde_json::to_value(storage(None)).unwrap();
    for field in [
        "message",
        "metadata",
        "body",
        "name",
        "tags",
        "clipboard",
        "record_id",
        "path",
        "key",
    ] {
        let mut bad = good.clone();
        bad["fields"][field] = serde_json::json!("PRIVATE");
        assert!(serde_json::from_value::<Event>(bad).is_err(), "{field}");
    }
    for (field, value) in [
        ("count", serde_json::json!(1_000_001)),
        ("count", serde_json::json!(true)),
        ("count", serde_json::json!(-1)),
        ("duration_ms", serde_json::json!(86_400_001)),
        ("duration_ms", serde_json::json!(1.5)),
    ] {
        let mut bad = good.clone();
        bad["fields"][field] = value;
        assert!(serde_json::from_value::<Event>(bad).is_err());
    }
    let mut bad = good;
    bad["event"] = serde_json::json!("arbitrary_text");
    assert!(serde_json::from_value::<Event>(bad).is_err());
}
#[test]
fn closed_events_round_trip_and_select_persistence_policy() {
    let events = [
        Event::Lifecycle {
            state: Lifecycle::Started,
        },
        Event::Lifecycle {
            state: Lifecycle::WillTerminate,
        },
        Event::Readiness {
            recovery_required: true,
            ordinary_count: Count::new(2),
        },
        storage(None),
        Event::Account {
            operation: AccountOperation::DeletionReview,
            stage: Stage::Confirm,
            state: AccountState::DeletionReview,
            outcome: Outcome::Attention,
            duration_ms: Milliseconds::new(Duration::ZERO),
            received_count: Count::new(0),
            accepted_count: Count::new(0),
            conflict_count: Count::new(0),
            rejected_count: Count::new(0),
            failure: None,
        },
        Event::Vault {
            operation: VaultOperation::Lock,
            outcome: Outcome::Succeeded,
            duration_ms: Milliseconds::new(Duration::ZERO),
            failure: None,
        },
        Event::QueueLoss {
            count: Count::new(12),
        },
    ];
    for event in events {
        assert_eq!(
            serde_json::from_slice::<Event>(&serde_json::to_vec(&event).unwrap()).unwrap(),
            event
        );
    }
    assert!(!storage(None).synchronous());
    assert!(events[1].synchronous());
    assert!(events[4].synchronous());
    assert_eq!(events[6].level(), "warning");
}
#[test]
fn uninstalled_facade_is_inert() {
    assert!(SINK.get().is_none());
    record(Event::Lifecycle {
        state: Lifecycle::Started,
    });
    assert!(SINK.get().is_none());
}
#[test]
fn cloud_failure_codes_are_stable_and_discard_server_retry_payloads() {
    use crate::cloud::{ErrorCode as C, Failure as F};
    for (failure, code) in [
        (F::Network, 6),
        (F::InvalidCredential, 3),
        (
            F::Server {
                code: C::InvalidAccountKey,
                retry_after: Some(u32::MAX),
            },
            120,
        ),
        (
            F::Server {
                code: C::InvalidRequest,
                retry_after: None,
            },
            105,
        ),
        (
            F::Server {
                code: C::InternalError,
                retry_after: None,
            },
            119,
        ),
        (
            F::Server {
                code: C::RateLimited,
                retry_after: None,
            },
            116,
        ),
    ] {
        assert_eq!(
            serde_json::to_value(Failure::from_cloud(failure)).unwrap(),
            serde_json::json!({"family":"cloud","code":code})
        );
    }
}

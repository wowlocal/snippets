//! Aggregate classifications at the serialized native account boundary.
use super::*;
use crate::diagnostics::{self, AccountOperation as Op, AccountState as State, Stage};

pub(super) fn operation(command: &Command) -> Option<(Op, Stage)> {
    Some(match command {
        Command::CreateAccount { .. } => (Op::AccountCreate, Stage::Perform),
        Command::SignIn { .. } => (Op::AccountSignIn, Stage::Perform),
        Command::BeginDeviceSignIn { .. } => (Op::DeviceRequest, Stage::Perform),
        Command::CancelDeviceSignIn => (Op::DeviceRequest, Stage::Cancel),
        Command::CheckDeviceSignIn => (Op::DeviceClaim, Stage::Perform),
        Command::PrepareDeviceApproval(_) => (Op::DeviceApproval, Stage::Prepare),
        Command::ApproveDevice(_) => (Op::DeviceApproval, Stage::Confirm),
        Command::Resume | Command::Refresh => (Op::Reconnect, Stage::Resume),
        Command::SignOut => (Op::SignOut, Stage::Perform),
        Command::CreateLibrary | Command::CreateNewLibrary(_) => {
            (Op::CreateLibrary, Stage::Perform)
        }
        Command::PrepareNewLibrary => (Op::CreateLibrary, Stage::Prepare),
        Command::Select(_) => (Op::SelectLibrary, Stage::Perform),
        Command::Setup | Command::BootstrapCandidate => (Op::KeySetup, Stage::Perform),
        Command::Recover(_) => (Op::KeyRecovery, Stage::Perform),
        Command::BeginPairing | Command::CandidatePairing(_) => (Op::Pairing, Stage::Perform),
        Command::CancelPairing => (Op::Pairing, Stage::Cancel),
        Command::PrepareHandover(_) => (Op::Handover, Stage::Prepare),
        Command::CommitHandover { .. } => (Op::Handover, Stage::Confirm),
        Command::ResumeHandover(_) | Command::FinishLocalHandover(_) => {
            (Op::Handover, Stage::Resume)
        }
        Command::CancelHandover(_) => (Op::Handover, Stage::Cancel),
        Command::PrepareRestoration { .. } | Command::PrepareMultipleRestoration { .. } => {
            (Op::HistoryRestore, Stage::Prepare)
        }
        Command::CommitRestoration { .. } => (Op::HistoryRestore, Stage::Confirm),
        Command::FinishRestoration { cancel, .. } => (
            Op::HistoryRestore,
            if *cancel {
                Stage::Cancel
            } else {
                Stage::Resume
            },
        ),
        Command::PrepareHistoryRemoval { .. } | Command::PrepareRecoveryFileCleanup(_) => {
            (Op::HistoryRemoval, Stage::Prepare)
        }
        Command::CommitHistoryRemoval { .. } => (Op::HistoryRemoval, Stage::Confirm),
        Command::Receive => (Op::Receive, Stage::Perform),
        Command::Send => (Op::Send, Stage::Perform),
        Command::Sync => (Op::Sync, Stage::Perform),
        Command::Automatic(_) => (Op::Automatic, Stage::Perform),
        Command::PrepareVaultSync(_) => (Op::VaultSync, Stage::Prepare),
        Command::ContinueVaultSync { .. } => (Op::VaultSync, Stage::Confirm),
        Command::CancelVaultSync => (Op::VaultSync, Stage::Cancel),
        Command::PrepareSnapshotReview => (Op::SnapshotReview, Stage::Prepare),
        Command::ResumeSnapshotReview(_) => (Op::SnapshotReview, Stage::Confirm),
        Command::PrepareDeletionReview => (Op::DeletionReview, Stage::Prepare),
        Command::DecideDeletionReview { .. } => (Op::DeletionReview, Stage::Confirm),
        Command::PrepareRecoveryMutation | Command::PrepareApproval(_) => {
            (Op::RecoveryMutation, Stage::Prepare)
        }
        Command::Mutate(_) => (Op::RecoveryMutation, Stage::Perform),
        Command::ReconcileMutation => (Op::RecoveryMutation, Stage::Resume),
        Command::CancelMutation => (Op::RecoveryMutation, Stage::Cancel),
        Command::Authenticate { .. } => (Op::Authenticate, Stage::Perform),
        Command::Reveal(_) => (Op::RecoveryDisclosure, Stage::Perform),
        Command::Confirm { .. } => (Op::RecoveryDisclosure, Stage::Confirm),
        // Read-only inspection and invitation polling are deliberately quiet.
        _ => return None,
    })
}
fn receive_state(status: receiver::Status) -> State {
    use receiver::Status as S;
    match status {
        S::Current => State::Current,
        S::MorePages => State::MorePages,
        S::LocalReview => State::LocalReview,
        S::ConflictReview => State::ConflictReview,
        S::VaultLocked => State::VaultLocked,
        S::IncompatibleVault => State::IncompatibleVault,
        S::SnapshotReview => State::SnapshotReview,
        S::DeletionReview => State::DeletionReview,
        S::PrimaryChanged => State::PrimaryChanged,
        S::SendFirst => State::SendFirst,
    }
}
fn send_state(status: sender::Status) -> State {
    use sender::Status as S;
    match status {
        S::Settled => State::Current,
        S::MoreBatches => State::MoreBatches,
        S::ReceiveFirst => State::ReceiveFirst,
        S::LocalReview => State::LocalReview,
        S::SnapshotReview => State::SnapshotReview,
        S::PreservationRequired => State::PreservationRequired,
        S::ConflictReview => State::ConflictReview,
        S::VaultLocked => State::VaultLocked,
        S::IncompatibleVault => State::IncompatibleVault,
        S::DeletionReview => State::DeletionReview,
        S::PrimaryChanged => State::PrimaryChanged,
        S::ReadOnly => State::ReadOnly,
        S::ServerDeferred { .. } => State::ServerDeferred,
    }
}
/// Claim polling repeats every few seconds while a request is pending. Like
/// invitation polling it stays quiet; only an approval or a failure is recorded.
pub(super) fn quiet(operation: (Op, Stage), result: &Result<Reply>) -> bool {
    operation.0 == Op::DeviceClaim
        && matches!(result, Ok(Reply::DeviceSignIn { failure: None, .. }))
}
pub(super) fn event(
    operation: (Op, Stage),
    started: std::time::Instant,
    result: &Result<Reply>,
) -> diagnostics::Event {
    use diagnostics::{Count, Family, Milliseconds, Outcome};
    let failure = match result {
        Err(failure) => Some(*failure),
        Ok(Reply::Library {
            outcome: Err(failure),
            ..
        })
        | Ok(Reply::Selected {
            keys: Err(failure), ..
        }) => Some(Failure::Key(*failure)),
        Ok(Reply::CreationFailed { failure, .. })
        | Ok(Reply::AccountCreated {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::DeviceSignIn {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::DeviceSignedIn {
            failure: Some(failure),
            ..
        }) => Some(*failure),
        Ok(Reply::DeviceSignedIn {
            keys: Some(Err(failure)),
            ..
        }) => Some(Failure::Key(*failure)),
        Ok(Reply::Restored {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::LocalHandover {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::Handover {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::Pairing {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::CandidatePairing {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::BootstrapCandidate {
            failure: Some(failure),
            ..
        })
        | Ok(Reply::Mutation {
            failure: Some(failure),
            ..
        }) => Some(*failure),
        Ok(Reply::Pairing {
            state: Err(failure),
            ..
        })
        | Ok(Reply::CandidatePairing {
            state: Err(failure),
            ..
        })
        | Ok(Reply::BootstrapCandidate {
            state: Err(failure),
            ..
        })
        | Ok(Reply::Mutation {
            state: Err(failure),
            ..
        })
        | Ok(Reply::Selected {
            pairing: Err(failure),
            ..
        })
        | Ok(Reply::Selected {
            mutation: Err(failure),
            ..
        }) => Some(Failure::Key(*failure)),
        _ => None,
    };
    let (state, counts) = match result {
        Ok(Reply::Received(p)) => (receive_state(p.status), [p.received_records, 0, 0, 0]),
        Ok(Reply::Sent(p)) => (
            send_state(p.status),
            [0, p.accepted, p.conflicts, p.rejected],
        ),
        Ok(Reply::Synchronized(p)) => {
            let state = match p.status {
                data_sync::Status::Current => State::Current,
                data_sync::Status::MoreWork(data_sync::Direction::Receive) => State::MorePages,
                data_sync::Status::MoreWork(data_sync::Direction::Send) => State::MoreBatches,
                data_sync::Status::Receiving(status) => receive_state(status),
                data_sync::Status::Sending(status) => send_state(status),
            };
            (
                state,
                [p.received_records, p.accepted, p.conflicts, p.rejected],
            )
        }
        _ => (State::NotApplicable, [0; 4]),
    };
    let cancelled = matches!(
        result,
        Ok(Reply::Restored {
            cancelled: true,
            ..
        }) | Ok(Reply::Handover {
            cancelled: true,
            ..
        })
    );
    let outcome = if result.is_err() {
        Outcome::Failed
    } else if failure.is_some() {
        Outcome::Attention
    } else if cancelled {
        Outcome::Cancelled
    } else {
        match state {
            State::NotApplicable | State::Current => Outcome::Succeeded,
            State::MorePages | State::MoreBatches | State::ReceiveFirst | State::SendFirst => {
                Outcome::MoreWork
            }
            _ => Outcome::Attention,
        }
    };
    let failure = failure.map(|failure| {
        if let Failure::Cloud(failure) = failure {
            return diagnostics::Failure::from_cloud(failure);
        }
        diagnostics::Failure::classified(match failure {
            Failure::Secret(_) => Family::SecretService,
            Failure::Account(_) | Failure::Cloud(_) => Family::Cloud,
            Failure::Authentication(_) => Family::Authentication,
            Failure::VaultAuthentication | Failure::PreviousVaultAuthentication => Family::Vault,
            Failure::Receive(_)
            | Failure::SnapshotReview(_)
            | Failure::DeletionReview(_)
            | Failure::Automatic(_) => Family::Sync,
            Failure::Key(_)
            | Failure::HistoryRemoval(_)
            | Failure::Handover(_)
            | Failure::Restoration(_) => Family::Storage,
            _ => Family::Other,
        })
    });
    diagnostics::Event::Account {
        operation: operation.0,
        stage: operation.1,
        state,
        outcome,
        duration_ms: Milliseconds::new(started.elapsed()),
        received_count: Count::new(counts[0]),
        accepted_count: Count::new(counts[1]),
        conflict_count: Count::new(counts[2]),
        rejected_count: Count::new(counts[3]),
        failure,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credentials_and_read_only_polling_do_not_enter_account_records() {
        const KEY: &str = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7";
        let key = || AccountKey::from_canonical(KEY).unwrap();
        let command = Command::SignIn {
            server: Zeroizing::new("https://PRIVATE.example".into()),
            key: key(),
        };
        let result: Result<Reply> = Err(Failure::Cloud(cloud::Failure::Server {
            code: cloud::ErrorCode::InvalidAccountKey,
            retry_after: None,
        }));
        let value = serde_json::to_value(event(
            operation(&command).unwrap(),
            std::time::Instant::now(),
            &result,
        ))
        .unwrap();
        assert_eq!(value["fields"]["operation"], "account_sign_in");
        assert_eq!(value["fields"]["outcome"], "failed");
        assert_eq!(
            value["fields"]["failure"],
            serde_json::json!({"family":"cloud","code":120})
        );
        let text = value.to_string();
        assert!(!text.contains("PRIVATE") && !text.contains(KEY) && !text.contains("7KQF"));
        let command = Command::CreateAccount {
            server: Zeroizing::new("https://PRIVATE.example".into()),
        };
        let result = Ok(Reply::AccountCreated {
            key: key(),
            next: Some(Box::new(Reply::Profile {
                account: Some("1A2B-3C4D".into()),
                server: None,
                interrupted: false,
                switching: handover::Status::default(),
                device: None,
            })),
            failure: Some(Failure::Cloud(cloud::Failure::Network)),
        });
        let value = serde_json::to_value(event(
            operation(&command).unwrap(),
            std::time::Instant::now(),
            &result,
        ))
        .unwrap();
        assert_eq!(value["fields"]["operation"], "account_create");
        assert_eq!(value["fields"]["outcome"], "attention");
        assert_eq!(value["fields"]["failure"]["code"], 6);
        let text = value.to_string();
        assert!(!text.contains("PRIVATE") && !text.contains("7KQF") && !text.contains("1A2B"));
        assert!(operation(&Command::Inspect).is_none());
        assert!(operation(&Command::CheckPairing).is_none());
        assert!(operation(&Command::PrepareAccountKeyDisclosure).is_none());
    }
    #[test]
    fn device_sign_in_records_closed_outcomes_without_ids_tokens_or_payloads() {
        use crate::auth_store::device::Status;
        let draft = crate::bootstrap::PairingDraft::generate().unwrap();
        let now = chrono::Utc::now().timestamp();
        let payload = crate::bootstrap::DeviceSignIn::new(
            ServerURL::parse("https://private-device.example").unwrap(),
            uuid::Uuid::from_u128(0x7a6b5c4d),
            *draft.nonce(),
            *draft.public_key(),
            now + 300,
            now,
        )
        .unwrap();
        let encoded = String::from_utf8(payload.encode_qr().unwrap().to_vec()).unwrap();
        let code = payload.confirmation_code();
        let waiting = |failure| {
            Ok(Reply::DeviceSignIn {
                state: Some(Status::Waiting(payload.clone())),
                retry_after: Some(30),
                failure,
            })
        };
        let check = operation(&Command::CheckDeviceSignIn).unwrap();
        assert_eq!(check, (Op::DeviceClaim, Stage::Perform));
        // Pending polls stay quiet; a failed poll is recorded as a closed code.
        assert!(quiet(check, &waiting(None)));
        let limited = waiting(Some(Failure::Cloud(cloud::Failure::Server {
            code: cloud::ErrorCode::RateLimited,
            retry_after: Some(30),
        })));
        assert!(!quiet(check, &limited));
        let value =
            serde_json::to_value(event(check, std::time::Instant::now(), &limited)).unwrap();
        assert_eq!(value["fields"]["operation"], "device_claim");
        assert_eq!(value["fields"]["outcome"], "attention");
        assert_eq!(
            value["fields"]["failure"],
            serde_json::json!({"family":"cloud","code":116})
        );
        let begin = Command::BeginDeviceSignIn {
            server: Zeroizing::new("https://private-device.example".into()),
        };
        let prepare = Command::PrepareDeviceApproval(Zeroizing::new(encoded.clone()));
        for (command, name) in [
            (&begin, "device_request"),
            (&Command::CancelDeviceSignIn, "device_request"),
            (&prepare, "device_approval"),
        ] {
            let operation = operation(command).unwrap();
            assert!(!quiet(operation, &waiting(None)));
            let text =
                serde_json::to_value(event(operation, std::time::Instant::now(), &waiting(None)))
                    .unwrap()
                    .to_string();
            assert!(text.contains(name));
            for private in [
                "private-device",
                "7a6b5c4d",
                "sn_d_",
                code.as_str(),
                &encoded[..20],
            ] {
                assert!(!text.contains(private), "{private}");
            }
        }
        let library = Ok(Reply::DeviceSignedIn {
            libraries: Box::new(Reply::Saved),
            library: None,
            selected: None,
            keys: None,
            failure: Some(Failure::DeviceLibraryUnavailable),
        });
        let value =
            serde_json::to_value(event(check, std::time::Instant::now(), &library)).unwrap();
        assert_eq!(value["fields"]["outcome"], "attention");
        assert_eq!(value["fields"]["failure"]["family"], "other");
    }
    #[test]
    fn partial_sync_and_nested_failures_are_not_reported_as_complete() {
        let result = Ok(Reply::Received(receiver::Progress {
            status: receiver::Status::DeletionReview,
            received_records: usize::MAX,
            applied_records: 0,
            completed_pages: 1,
        }));
        let value = serde_json::to_value(event(
            (Op::Receive, Stage::Perform),
            std::time::Instant::now(),
            &result,
        ))
        .unwrap();
        assert_eq!(value["fields"]["state"], "deletion_review");
        assert_eq!(value["fields"]["outcome"], "attention");
        assert_eq!(value["fields"]["received_count"], 1_000_000);
        let result = Ok(Reply::Library {
            outcome: Err(key_store::Failure::KeyConflict),
            can_create_new: Ok(false),
        });
        let value = serde_json::to_value(event(
            (Op::KeySetup, Stage::Perform),
            std::time::Instant::now(),
            &result,
        ))
        .unwrap();
        assert_eq!(value["fields"]["outcome"], "attention");
        assert_eq!(value["fields"]["failure"]["family"], "storage");
    }
}

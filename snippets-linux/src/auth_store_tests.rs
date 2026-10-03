//! Fictional tokens/account metadata; every archive lives in an isolated backend.
//! Account keys are the public ADR 0006 test vectors, never real credentials.
use super::*;
use crate::secret_store::{Store, tests::Memory};
const KEY: &str = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7";
const OTHER_KEY: &str = "0123456789ABCDEFGHJKMNPQRS45";
/// Native account identities are UUIDs; fixtures derive stable public ones.
fn account_id(name: &str) -> String {
    Uuid::new_v5(&Uuid::NAMESPACE_OID, name.as_bytes()).to_string()
}
fn display(name: &str) -> String {
    crate::account_key::account_id_display(&account_id(name)).unwrap()
}
fn grant_bytes(label: &str, account: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({"access_token":format!("public-{label}-access"),"refresh_token":format!("public-{label}-refresh"),"expires_in":300,"token_type":"Bearer","account":{"id":account_id(account)}})).unwrap()
}
fn deployment() -> Deployment {
    Deployment::from_discovery(
        ServerURL::parse("https://cloud.example.test").unwrap(),
        Uuid::from_u128(1),
    )
}
fn issued(label: &str) -> IssuedCredentials {
    IssuedCredentials {
        access: Credential::new(format!("public-{label}-access")).unwrap(),
        refresh: Credential::new(format!("public-{label}-refresh")).unwrap(),
    }
}
/// A grant as returned by sign-in with the public fixture key. Refresh accepts
/// it too, because a rotation may only repeat the saved account's own key.
fn grant(label: &str, account: &str) -> cloud::IssuedGrant {
    cloud::IssuedGrant::fixture_signed_in(&grant_bytes(label, account), KEY).unwrap()
}
fn refreshed(label: &str, account: &str) -> cloud::IssuedGrant {
    cloud::IssuedGrant::fixture(&grant_bytes(label, account)).unwrap()
}
fn operate<T>(
    store: &mut Store<Memory>,
    action: impl FnOnce(&mut Archive, &mut Locked<'_, Memory>) -> Result<T>,
) -> Result<T> {
    store.transaction_with(|owner| {
        let mut archive = Archive::load(owner)?;
        action(&mut archive, owner)
    })
}
fn receipt(action: CleanupAction) -> CleanupReceipt {
    CleanupReceipt {
        generation: action.generation,
        index: action.index,
        deployment: action.deployment,
        token: action.token,
        refresh: action.refresh,
    }
}
fn install(store: &mut Store<Memory>, label: &str) {
    operate(store, |archive, owner| {
        let lease = archive.begin(Replacement::Interactive, deployment())?;
        archive.save(owner)?;
        let session = grant(label, "public-account")
            .accept(
                |credentials| {
                    archive
                        .stage_issued(&lease, credentials)
                        .map_err(|_| cloud::Failure::CredentialCommit)?;
                    archive
                        .save(owner)
                        .map_err(|_| cloud::Failure::CredentialCommit)
                },
                None,
                None,
            )
            .map_err(|e| Failure::Cloud(e.failure))?;
        archive.publish(&lease, &session, 1000)?;
        archive.save(owner)?;
        archive.begin_cleanup(&lease)?;
        archive.finish_cleanup(&lease)?;
        archive.save(owner)
    })
    .unwrap();
}
fn fixture() -> (tempfile::TempDir, Store<Memory>, Memory) {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let store = Store::initialize(root.path(), memory.clone()).unwrap();
    (root, store, memory)
}
#[test]
fn cancelled_refresh_never_starts_a_credential_transition_or_request() {
    let (root, mut store, _) = fixture();
    install(&mut store, "cancelled-refresh");
    let before = store
        .transaction(|owner| owner.read(Slot::Credentials))
        .unwrap()
        .unwrap();
    let client = CloudClient::test_with_agent(
        deployment().server().clone(),
        ureq::Agent::new_with_defaults(),
        deployment().instance(),
    );
    let error = refresh_bound(&mut store, &client, &|| Err(Failure::Stale), &|_, _| {
        panic!("cancelled refresh must not observe or send a token")
    })
    .err()
    .unwrap();
    assert_eq!(error.failure, Failure::Stale);
    assert!(error.unrecorded.is_none());
    assert_eq!(
        store
            .transaction(|owner| owner.read(Slot::Credentials))
            .unwrap()
            .unwrap()
            .as_slice(),
        before.as_slice()
    );
    assert!(!root.path().join("Sync").exists());
}
#[test]
fn bound_refresh_refuses_a_replaced_account_before_any_network_operation() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "changed-account");
    let client = CloudClient::test_with_agent(
        deployment().server().clone(),
        ureq::Agent::new_with_defaults(),
        deployment().instance(),
    );
    let error = refresh_bound(&mut store, &client, &|| Ok(()), &|d, account| {
        assert!(*d == deployment());
        assert_eq!(account, account_id("public-account"));
        Err(Failure::WrongDeployment)
    })
    .err()
    .unwrap();
    assert_eq!(error.failure, Failure::WrongDeployment);
    assert!(error.unrecorded.is_none());
    operate(&mut store, |archive, _| {
        assert!(archive.current.is_some());
        assert!(matches!(archive.saved_deployment(), Err(Failure::Busy)));
        Ok(())
    })
    .unwrap();
}
#[test]
fn saved_account_observation_refuses_interrupted_lineage_without_network_or_mutation() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "saved-ui-profile");
    operate(&mut store, |archive, owner| {
        let before = owner.read(Slot::Credentials)?.unwrap();
        assert!(
            archive.saved_deployment()?.as_ref().map(Deployment::server)
                == Some(deployment().server())
        );
        assert!(owner.read(Slot::Credentials)?.unwrap().as_slice() == before.as_slice());
        archive.begin(Replacement::Refresh, deployment())?;
        archive.save(owner)?;
        assert!(matches!(
            Archive::load(owner)?.saved_deployment(),
            Err(Failure::Busy)
        ));
        Ok(())
    })
    .unwrap();
}
#[test]
fn every_issued_pair_is_saved_before_invalid_metadata_can_be_accepted() {
    let (_root, mut store, _) = fixture();
    operate(&mut store, |archive, owner| {
        let lease = archive.begin(Replacement::Interactive, deployment())?;
        archive.save(owner)?;
        let result = grant("invalid", "foreign-account").accept(
            |credentials| {
                archive
                    .stage_issued(&lease, credentials)
                    .map_err(|_| cloud::Failure::CredentialCommit)?;
                archive
                    .save(owner)
                    .map_err(|_| cloud::Failure::CredentialCommit)
            },
            Some(account_id("expected-account").as_str()),
            None,
        );
        assert!(result.is_err());
        let mut restarted = Archive::load(owner)?;
        let lease = restarted.resume().unwrap();
        restarted.begin_cleanup(&lease)?;
        let actions = restarted.cleanup_actions(&lease)?;
        assert_eq!(actions.len(), 2);
        assert!(actions[0].token.as_str() == "public-invalid-access" && !actions[0].refresh);
        assert!(actions[1].token.as_str() == "public-invalid-refresh" && actions[1].refresh);
        assert!(restarted.profile_account() == Err(Failure::Busy));
        Ok(())
    })
    .unwrap();
}
#[test]
fn committed_refresh_retires_only_the_obsolete_access_token() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        let previous = archive.refresh_credential(&deployment())?;
        assert!(archive.account_for_refresh(&deployment())? == account_id("public-account"));
        let lease = archive.begin(Replacement::Refresh, deployment())?;
        archive.save(owner)?;
        let session = refreshed("new", "public-account")
            .accept(
                |credentials| {
                    archive
                        .stage_issued(&lease, credentials)
                        .map_err(|_| cloud::Failure::CredentialCommit)?;
                    archive
                        .save(owner)
                        .map_err(|_| cloud::Failure::CredentialCommit)
                },
                Some(account_id("public-account").as_str()),
                Some(&previous),
            )
            .map_err(|e| Failure::Cloud(e.failure))?;
        archive.publish(&lease, &session, 2000)?;
        archive.save(owner)?;
        let mut restored = Archive::load(owner)?;
        let lease = restored.resume().unwrap();
        restored.begin_cleanup(&lease)?;
        restored.save(owner)?;
        let actions = restored.cleanup_actions(&lease)?;
        assert_eq!(actions.len(), 1);
        assert!(!actions[0].refresh && actions[0].token.as_str() == "public-old-access");
        assert!(restored.refresh_credential(&deployment()).err() == Some(Failure::Busy));
        for action in actions {
            restored.acknowledge(receipt(action))?;
            restored.save(owner)?;
        }
        restored.finish_cleanup(&lease)?;
        restored.save(owner)?;
        let restored = Archive::load(owner)?;
        assert!(restored.profile_account()? == Some(display("public-account")));
        assert!(restored.account_key_for_disclosure()?.canonical() == KEY);
        assert!(
            restored
                .refresh_credential(&deployment())?
                .for_secure_storage()
                == b"public-new-refresh"
        );
        Ok(())
    })
    .unwrap();
}
#[test]
fn abandoned_refresh_revokes_both_generations_and_requires_sign_in_again() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        let lease = archive.begin(Replacement::Refresh, deployment())?;
        archive.save(owner)?;
        archive.stage_issued(&lease, &issued("abandoned"))?;
        archive.save(owner)?;
        let mut restored = Archive::load(owner)?;
        let lease = restored.resume().unwrap();
        restored.begin_cleanup(&lease)?;
        restored.save(owner)?;
        let mut actions = restored.cleanup_actions(&lease)?;
        assert_eq!(actions.len(), 4);
        assert!(actions.iter().filter(|a| a.refresh).count() == 2);
        restored.acknowledge(receipt(actions.remove(0)))?;
        restored.save(owner)?;
        assert!(restored.finish_cleanup(&lease) == Err(Failure::Busy));
        let mut again = Archive::load(owner)?;
        let lease = again.resume().unwrap();
        assert_eq!(again.cleanup_actions(&lease)?.len(), 3);
        for action in again.cleanup_actions(&lease)? {
            again.acknowledge(receipt(action))?;
            again.save(owner)?;
        }
        again.finish_cleanup(&lease)?;
        again.save(owner)?;
        assert!(Archive::load(owner)?.profile_account()?.is_none());
        Ok(())
    })
    .unwrap();
}
#[test]
fn interactive_replacement_preserves_old_session_until_publish_and_then_retires_its_family() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        let lease = archive.begin(Replacement::Interactive, deployment())?;
        archive.save(owner)?;
        archive.stage_issued(&lease, &issued("cancelled"))?;
        archive.begin_cleanup(&lease)?;
        for action in archive.cleanup_actions(&lease)? {
            assert!(action.token.starts_with("public-cancelled-"));
            archive.acknowledge(receipt(action))?;
        }
        archive.finish_cleanup(&lease)?;
        archive.save(owner)?;
        assert!(
            archive
                .refresh_credential(&deployment())?
                .for_secure_storage()
                == b"public-old-refresh"
        );
        let lease = archive.begin(Replacement::Interactive, deployment())?;
        let session = grant("replacement", "public-account")
            .accept(
                |credentials| {
                    archive
                        .stage_issued(&lease, credentials)
                        .map_err(|_| cloud::Failure::CredentialCommit)?;
                    archive
                        .save(owner)
                        .map_err(|_| cloud::Failure::CredentialCommit)
                },
                None,
                None,
            )
            .map_err(|e| Failure::Cloud(e.failure))?;
        archive.publish(&lease, &session, 2000)?;
        archive.begin_cleanup(&lease)?;
        let actions = archive.cleanup_actions(&lease)?;
        assert_eq!(actions.len(), 2);
        assert!(actions.iter().all(|a| a.token.starts_with("public-old-")));
        Ok(())
    })
    .unwrap();
}
#[test]
fn logout_is_durable_and_blocks_every_replacement_until_revocation_completes() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        archive.begin(Replacement::Logout, deployment())?;
        archive.save(owner)?;
        let mut restored = Archive::load(owner)?;
        let lease = restored.resume().unwrap();
        assert!(restored.begin(Replacement::Refresh, deployment()).err() == Some(Failure::Busy));
        assert!(restored.stage_issued(&lease, &issued("racing")) == Err(Failure::Busy));
        restored.begin_cleanup(&lease)?;
        for action in restored.cleanup_actions(&lease)? {
            restored.acknowledge(receipt(action))?;
        }
        restored.finish_cleanup(&lease)?;
        restored.save(owner)?;
        assert!(Archive::load(owner)?.profile_account()?.is_none());
        Ok(())
    })
    .unwrap();
}
#[test]
fn stale_leases_receipts_and_snapshots_cannot_authorize_or_erase_a_new_generation() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        let mut stale = Archive::load(owner)?;
        let lease = archive.begin(Replacement::Interactive, deployment())?;
        archive.stage_issued(&lease, &issued("A"))?;
        archive.begin_cleanup(&lease)?;
        let first = archive.cleanup_actions(&lease)?.remove(0);
        let old_receipt = CleanupReceipt {
            generation: first.generation,
            index: first.index,
            deployment: first.deployment.clone(),
            token: first.token.clone(),
            refresh: first.refresh,
        };
        for action in archive.cleanup_actions(&lease)? {
            archive.acknowledge(receipt(action))?;
        }
        archive.finish_cleanup(&lease)?;
        archive.save(owner)?;
        assert!(stale.save(owner).err() == Some(Failure::Secret(secret_store::Failure::Stale)));
        let next = archive.begin(Replacement::Interactive, deployment())?;
        archive.stage_issued(&next, &issued("B"))?;
        archive.begin_cleanup(&next)?;
        assert!(archive.acknowledge(old_receipt) == Err(Failure::Stale));
        assert!(archive.stage_issued(&lease, &issued("C")) == Err(Failure::Stale));
        let mut wrong = receipt(archive.cleanup_actions(&next)?.remove(0));
        wrong.index = 9;
        assert!(archive.acknowledge(wrong) == Err(Failure::Stale));
        Ok(())
    })
    .unwrap();
}
#[test]
fn cleanup_cannot_be_followed_by_publication_or_another_issued_family() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, _owner| {
        let lease = archive.begin(Replacement::Refresh, deployment())?;
        archive.stage_issued(&lease, &issued("new"))?;
        archive.begin_cleanup(&lease)?;
        let session = refreshed("new", "public-account")
            .accept(
                |_| Ok(()),
                Some(account_id("public-account").as_str()),
                None,
            )
            .map_err(|e| Failure::Cloud(e.failure))?;
        assert!(archive.publish(&lease, &session, 2000) == Err(Failure::Busy));
        assert!(archive.stage_issued(&lease, &issued("later")) == Err(Failure::Busy));
        Ok(())
    })
    .unwrap();
}
#[test]
fn strict_secret_schema_refuses_unknown_fields_duplicate_keys_and_invalid_lineage() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        let original = owner.read(Slot::Credentials)?.unwrap();
        for bad in [
            br#"{"schema":2,"schema":2,"generation":0,"current":null,"pending":null}"#.as_slice(),
            br#"{"schema":3,"generation":0,"current":null,"pending":null}"#,
            br#"{"schema":0,"generation":0,"current":null,"pending":null}"#,
            br#"{"schema":2,"generation":0,"current":null,"pending":null,"extra":true}"#,
            br#"{"schema":2,"generation":1.0,"current":null,"pending":null}"#,
            br#"{"schema":1,"generation":-1,"current":null,"pending":null}"#,
        ] {
            let current = owner.read(Slot::Credentials)?.unwrap();
            owner.replace(Slot::Credentials, Some(&current), Some(bad))?;
            assert!(Archive::load(owner).err() == Some(Failure::InvalidState));
        }
        let current = owner.read(Slot::Credentials)?.unwrap();
        owner.replace(Slot::Credentials, Some(&current), Some(&original))?;
        let lease = archive.begin(Replacement::Refresh, deployment())?;
        archive.stage_issued(&lease, &issued("new"))?;
        archive.begin_cleanup(&lease)?;
        archive.pending.as_mut().unwrap().acknowledged = 0x80;
        assert!(archive.save(owner) == Err(Failure::InvalidState));
        Ok(())
    })
    .unwrap();
}

#[test]
fn overlapping_grants_cannot_publish_and_cleanup_cannot_restore_a_revoked_session() {
    for kind in [Replacement::Interactive, Replacement::Refresh] {
        for (access, refresh) in [
            ("public-old-access", "public-new-refresh"),
            ("public-new-access", "public-old-refresh"),
            ("public-old-refresh", "public-new-refresh"),
            ("public-new-access", "public-old-access"),
        ] {
            let (_root, mut store, _) = fixture();
            install(&mut store, "old");
            operate(&mut store, |archive, owner| {
                let lease = archive.begin(kind, deployment())?;
                archive.save(owner)?;
                let bytes = serde_json::to_vec(&serde_json::json!({
                    "access_token":access,"refresh_token":refresh,"expires_in":300,
                    "token_type":"Bearer","account":{"id":account_id("public-account")}
                }))
                .unwrap();
                let session = cloud::IssuedGrant::fixture_signed_in(&bytes, KEY)
                    .unwrap()
                    .accept(
                        |pair| {
                            archive
                                .stage_issued(&lease, pair)
                                .map_err(|_| cloud::Failure::CredentialCommit)?;
                            archive
                                .save(owner)
                                .map_err(|_| cloud::Failure::CredentialCommit)
                        },
                        None,
                        None,
                    )
                    .map_err(|e| Failure::Cloud(e.failure))?;
                assert!(archive.publish(&lease, &session, 2000) == Err(Failure::InvalidState));
                let mut restarted = Archive::load(owner)?;
                let lease = restarted.resume().unwrap();
                restarted.begin_cleanup(&lease)?;
                for action in restarted.cleanup_actions(&lease)? {
                    restarted.acknowledge(receipt(action))?;
                }
                restarted.finish_cleanup(&lease)?;
                restarted.save(owner)?;
                assert!(Archive::load(owner)?.profile_account()?.is_none());
                Ok(())
            })
            .unwrap();
        }
    }
}

#[test]
fn durable_lineage_revalidates_account_tokens_and_logout_deployment() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    operate(&mut store, |archive, owner| {
        let mut foreign = deployment();
        foreign.instance = Uuid::from_u128(2);
        assert!(
            archive.begin(Replacement::Logout, foreign).err() == Some(Failure::WrongDeployment)
        );
        assert!(archive.pending.is_none());
        let lease = archive.begin(Replacement::Refresh, deployment())?;
        archive.stage_issued(&lease, &issued("new"))?;
        let session = grant("new", "public-account")
            .accept(|_| Ok(()), None, None)
            .map_err(|e| Failure::Cloud(e.failure))?;
        archive.publish(&lease, &session, 2000)?;
        archive.save(owner)?;
        let original = owner.read(Slot::Credentials)?.unwrap();
        for field in ["account", "access", "refresh"] {
            let mut value = canonical::parse(&original)?;
            let Value::Object(top) = &mut value else {
                unreachable!()
            };
            let Value::Object(current) = top.get_mut("current").unwrap() else {
                unreachable!()
            };
            if field == "account" {
                current.insert(
                    field.into(),
                    Value::text(account_id("foreign-account").as_str()),
                );
            } else {
                let Value::Object(pair) = current.get_mut("pair").unwrap() else {
                    unreachable!()
                };
                let bad = Value::text(format!("public-old-{field}").as_str());
                pair.insert(field.into(), bad.clone());
                let Value::Object(pending) = top.get_mut("pending").unwrap() else {
                    unreachable!()
                };
                let Value::Object(issued) = pending.get_mut("issued").unwrap() else {
                    unreachable!()
                };
                issued.insert(field.into(), bad);
            }
            let before = owner.read(Slot::Credentials)?.unwrap();
            owner.replace(Slot::Credentials, Some(&before), Some(&value.encode()?))?;
            assert!(Archive::load(owner).err() == Some(Failure::InvalidState));
        }
        Ok(())
    })
    .unwrap();
}

#[test]
fn owner_refresh_cleanup_failure_recovers_without_revoking_the_committed_family() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    let rejected = issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |previous| {
            assert!(previous.unwrap().refresh.for_secure_storage() == b"public-old-refresh");
            Ok(grant("new", "public-account"))
        },
        &mut |_| Err(Failure::Cloud(cloud::Failure::Network)),
    )
    .err()
    .unwrap();
    assert!(rejected.failure == Failure::Cloud(cloud::Failure::Network));
    assert!(rejected.unrecorded.is_none());
    operate(&mut store, |archive, _| {
        assert!(archive.current.as_ref().unwrap().pair.refresh.as_str() == "public-new-refresh");
        assert!(archive.pending.as_ref().unwrap().published);
        Ok(())
    })
    .unwrap();
    assert!(
        issue(
            &mut store,
            Replacement::Refresh,
            deployment(),
            |_| panic!("pending cleanup must stop issuance"),
            &mut |_| panic!("pending cleanup must stop issuance")
        )
        .err()
        .unwrap()
        .failure
            == Failure::Busy
    );
    let mut retired = Vec::new();
    recover_with(&mut store, &mut |action| {
        retired.push((action.token.as_str().to_owned(), action.refresh));
        Ok(receipt(action))
    })
    .unwrap();
    assert!(retired == [("public-old-access".into(), false)]);
    let live = issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |_| Ok(grant("newer", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(live.access().unwrap().for_secure_storage() == b"public-newer-access");
    assert!(live.account_display().unwrap() == display("public-account"));
}

#[test]
fn owner_network_ambiguity_and_invalid_account_leave_durable_cleanup_authority() {
    for invalid_metadata in [false, true] {
        let (_root, mut store, _) = fixture();
        install(&mut store, "old");
        let rejected = issue(
            &mut store,
            Replacement::Refresh,
            deployment(),
            |_| {
                if invalid_metadata {
                    Ok(grant("foreign", "another-account"))
                } else {
                    Err(Failure::Cloud(cloud::Failure::Network))
                }
            },
            &mut |_| panic!("invalid issuance cannot start cleanup implicitly"),
        )
        .err()
        .unwrap();
        assert!(rejected.unrecorded.is_none());
        let mut retired = Vec::new();
        recover_with(&mut store, &mut |a| {
            retired.push((a.token.as_str().to_owned(), a.refresh));
            Ok(receipt(a))
        })
        .unwrap();
        assert_eq!(retired.len(), if invalid_metadata { 4 } else { 2 });
        assert!(
            retired
                .iter()
                .any(|(t, hint)| t == "public-old-refresh" && *hint)
        );
        operate(&mut store, |archive, _| {
            assert!(archive.current.is_none() && archive.pending.is_none());
            Ok(())
        })
        .unwrap();
    }
}

#[test]
fn owner_retains_unrecorded_pairs_across_locked_and_ambiguous_secret_writes() {
    for ambiguous in [false, true] {
        let (_root, mut store, memory) = fixture();
        install(&mut store, "old");
        let mut rejected = issue(
            &mut store,
            Replacement::Refresh,
            deployment(),
            |_| {
                if ambiguous {
                    memory.0.lock().unwrap().fail_write_after = true;
                } else {
                    memory.0.lock().unwrap().fail_read = Some(secret_store::Failure::Locked);
                }
                Ok(grant("unrecorded", "public-account"))
            },
            &mut |_| panic!("failed commit cannot revoke anything"),
        )
        .err()
        .unwrap();
        assert!(matches!(rejected.failure, Failure::Secret(_)));
        let retained = rejected.unrecorded.take().unwrap();
        assert!(retained.credentials.refresh.for_secure_storage() == b"public-unrecorded-refresh");
        // Retry failure returns ownership again, rather than dropping the pair.
        let mut retry = retained.retain(&mut store).err().unwrap();
        let retained = retry.unrecorded.take().unwrap();
        memory.0.lock().unwrap().fail_read = None;
        memory.0.lock().unwrap().fail_write_after = false;
        retained
            .retain(&mut store)
            .unwrap_or_else(|e| panic!("{:?}", e.failure));
        let mut retired = Vec::new();
        recover_with(&mut store, &mut |a| {
            retired.push(a.token.as_str().to_owned());
            Ok(receipt(a))
        })
        .unwrap();
        assert_eq!(retired.len(), 4);
        assert!(retired.iter().any(|s| s == "public-unrecorded-refresh"));
        assert!(retired.iter().any(|s| s == "public-old-refresh"));
    }
}

#[test]
fn old_unrecorded_owner_cannot_replace_a_later_pending_generation() {
    let (_root, mut store, memory) = fixture();
    install(&mut store, "old");
    let mut rejected = issue(
        &mut store,
        Replacement::Interactive,
        deployment(),
        |_| {
            memory.0.lock().unwrap().fail_read = Some(secret_store::Failure::Locked);
            Ok(grant("stale", "public-account"))
        },
        &mut |_| unreachable!(),
    )
    .err()
    .unwrap();
    memory.0.lock().unwrap().fail_read = None;
    // Simulate a caller breaking the retain-before-recover contract. Even then
    // an old error cannot clobber a newer grant's cleanup authority.
    recover_with(&mut store, &mut |a| Ok(receipt(a))).unwrap();
    operate(&mut store, |archive, owner| {
        let lease = archive.begin(Replacement::Interactive, deployment())?;
        archive.stage_issued(&lease, &issued("later"))?;
        archive.save(owner)
    })
    .unwrap();
    let retry = rejected
        .unrecorded
        .take()
        .unwrap()
        .retain(&mut store)
        .err()
        .unwrap();
    assert!(retry.failure == Failure::Stale && retry.unrecorded.is_some());
    operate(&mut store, |archive, _| {
        assert!(
            archive
                .pending
                .as_ref()
                .unwrap()
                .issued
                .as_ref()
                .unwrap()
                .access
                .as_str()
                == "public-later-access"
        );
        Ok(())
    })
    .unwrap();
}

#[test]
fn owner_logout_replays_only_unacknowledged_revocations_and_empty_recovery_does_no_io() {
    let (_root, mut store, _) = fixture();
    recover_with(&mut store, &mut |_| panic!("empty store must not use HTTP")).unwrap();
    store
        .transaction(|owner| {
            assert!(owner.read(Slot::Credentials)?.is_none());
            Ok(())
        })
        .unwrap();
    sign_out_with(&mut store, &mut |_| {
        panic!("empty logout must not use HTTP")
    })
    .unwrap();
    install(&mut store, "old");
    let mut count = 0;
    let result = sign_out_with(&mut store, &mut |action| {
        count += 1;
        if count == 2 {
            return Err(Failure::Cloud(cloud::Failure::Network));
        }
        assert!(!action.refresh);
        Ok(receipt(action))
    });
    assert!(result == Err(Failure::Cloud(cloud::Failure::Network)));
    let mut retired = Vec::new();
    recover_with(&mut store, &mut |action| {
        retired.push((action.token.as_str().to_owned(), action.refresh));
        Ok(receipt(action))
    })
    .unwrap();
    assert!(retired == [("public-old-refresh".into(), true)]);
    sign_out_with(&mut store, &mut |_| {
        panic!("completed logout must not use HTTP")
    })
    .unwrap();
}

#[test]
fn live_credentials_expire_on_either_clock_and_wrong_deployment_never_issues() {
    let (_root, mut store, _) = fixture();
    install(&mut store, "old");
    let mut foreign = deployment();
    foreign.instance = Uuid::from_u128(2);
    assert!(
        issue(
            &mut store,
            Replacement::Refresh,
            foreign,
            |_| panic!("foreign deployment must not receive a refresh token"),
            &mut |_| unreachable!()
        )
        .err()
        .unwrap()
        .failure
            == Failure::WrongDeployment
    );
    let mut live = issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |_| Ok(grant("new", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    let monotonic = live.monotonic_deadline;
    live.monotonic_deadline = std::time::Duration::ZERO;
    assert!(live.access().err() == Some(Failure::Expired));
    live.monotonic_deadline = monotonic;
    live.wall_deadline = std::time::UNIX_EPOCH;
    assert!(live.access().err() == Some(Failure::Expired));
}
#[test]
fn offline_live_validation_refuses_replaced_logged_out_pending_or_foreign_credentials_without_mutation()
 {
    let (_root, mut store, memory) = fixture();
    let mut live = issue(
        &mut store,
        Replacement::Interactive,
        deployment(),
        |_| Ok(grant("live-owner", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("closed credential failure: {:?}", e.failure));
    let client = CloudClient::test_with_agent(
        deployment().server.clone(),
        ureq::Agent::new_with_defaults(),
        deployment().instance,
    );
    let before = store
        .transaction(|o| o.read(Slot::Credentials))
        .unwrap()
        .unwrap();
    validate_session(&mut store, &client, &live).unwrap();
    assert!(
        store
            .transaction(|o| o.read(Slot::Credentials))
            .unwrap()
            .unwrap()
            == before
    );
    let foreign = CloudClient::test_with_agent(
        deployment().server.clone(),
        ureq::Agent::new_with_defaults(),
        Uuid::from_u128(2),
    );
    assert!(validate_session(&mut store, &foreign, &live) == Err(Failure::Stale));
    let origin = CloudClient::test_with_agent(
        ServerURL::parse("https://foreign.example.test").unwrap(),
        ureq::Agent::new_with_defaults(),
        deployment().instance,
    );
    assert!(validate_session(&mut store, &origin, &live) == Err(Failure::Stale));
    memory.0.lock().unwrap().fail_read = Some(secret_store::Failure::Locked);
    assert!(
        validate_session(&mut store, &client, &live)
            == Err(Failure::Secret(secret_store::Failure::Locked))
    );
    memory.0.lock().unwrap().fail_read = None;
    let next = issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |_| Ok(grant("rotated-owner", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("closed credential failure: {:?}", e.failure));
    assert!(validate_session(&mut store, &client, &live) == Err(Failure::Stale));
    validate_session(&mut store, &client, &next).unwrap();
    live.monotonic_deadline = std::time::Duration::ZERO;
    assert!(validate_session(&mut store, &client, &live) == Err(Failure::Expired));
    let changed = issue(
        &mut store,
        Replacement::Interactive,
        deployment(),
        |_| Ok(grant("changed-account", "public-other-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("closed credential failure: {:?}", e.failure));
    assert!(validate_session(&mut store, &client, &next) == Err(Failure::Stale));
    validate_session(&mut store, &client, &changed).unwrap();
    sign_out_with(&mut store, &mut |a| Ok(receipt(a))).unwrap();
    assert!(validate_session(&mut store, &client, &changed) == Err(Failure::InvalidState));
    let pending = issue(
        &mut store,
        Replacement::Interactive,
        deployment(),
        |_| Ok(grant("pending-owner", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("closed credential failure: {:?}", e.failure));
    operate(&mut store, |archive, owner| {
        archive.begin(Replacement::Refresh, deployment())?;
        archive.save(owner)
    })
    .unwrap();
    assert!(validate_session(&mut store, &client, &pending) == Err(Failure::Busy));
    assert!(
        store
            .transaction(|o| o.read(Slot::LibraryKey))
            .unwrap()
            .is_none()
    );
}

#[test]
fn lost_revocation_receipt_persistence_replays_safely_and_stops_before_the_next_token() {
    for ambiguous in [false, true] {
        let (_root, mut store, memory) = fixture();
        install(&mut store, "old");
        let mut sent = 0;
        let result = sign_out_with(&mut store, &mut |action| {
            sent += 1;
            assert_eq!(sent, 1, "a failed receipt write must stop the batch");
            assert!(!action.refresh);
            if ambiguous {
                memory.0.lock().unwrap().fail_write_after = true;
            } else {
                memory.0.lock().unwrap().fail_read = Some(secret_store::Failure::Locked);
            }
            Ok(receipt(action))
        });
        assert!(matches!(result, Err(Failure::Secret(_))));
        memory.0.lock().unwrap().fail_read = None;
        memory.0.lock().unwrap().fail_write_after = false;
        let mut replayed = Vec::new();
        recover_with(&mut store, &mut |action| {
            replayed.push(action.refresh);
            Ok(receipt(action))
        })
        .unwrap();
        assert!(
            replayed
                == if ambiguous {
                    vec![true]
                } else {
                    vec![false, true]
                }
        );
        operate(&mut store, |archive, _| {
            assert!(archive.current.is_none() && archive.pending.is_none());
            Ok(())
        })
        .unwrap();
    }
}

fn creation(label: &str, account: &str, key: serde_json::Value) -> cloud::IssuedGrant {
    let session: serde_json::Value = serde_json::from_slice(&grant_bytes(label, account)).unwrap();
    cloud::IssuedGrant::fixture_created(
        &serde_json::to_vec(&serde_json::json!({"accountKey":key,"session":session})).unwrap(),
    )
    .unwrap()
}
fn stored(store: &mut Store<Memory>) -> Vec<u8> {
    store
        .transaction(|owner| owner.read(Slot::Credentials))
        .unwrap()
        .map_or_else(Vec::new, |bytes| bytes.to_vec())
}
fn contains(haystack: &[u8], needle: &str) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle.as_bytes())
}

#[test]
fn account_key_is_stored_with_its_session_kept_by_refresh_and_removed_on_sign_out() {
    let (_root, mut store, _) = fixture();
    let (live, key) = create_account_with(
        &mut store,
        deployment(),
        |previous| {
            assert!(previous.is_none());
            Ok(creation(
                "created",
                "public-account",
                serde_json::json!(KEY),
            ))
        },
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(key.canonical() == KEY);
    assert!(live.session.issued_account_key().is_none());
    assert!(live.account_display().unwrap() == display("public-account"));
    let document = stored(&mut store);
    let value = canonical::parse(&document).unwrap();
    assert!(value.as_object().unwrap()["schema"].as_int().unwrap() == 2);
    assert!(contains(
        &document,
        "\"accountKey\":\"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7\""
    ));
    assert!(!contains(&document, "email"));
    // A rotation never carries a key; the saved account's key is kept.
    issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |_| Ok(refreshed("rotated", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    operate(&mut store, |archive, _| {
        assert!(archive.account_key_for_disclosure()?.canonical() == KEY);
        Ok(())
    })
    .unwrap();
    // Signing in to another account replaces both the session and its key.
    let other = AccountKey::from_canonical(OTHER_KEY).unwrap();
    let signed_in = issue(
        &mut store,
        Replacement::Interactive,
        deployment(),
        |_| {
            Ok(cloud::IssuedGrant::fixture_signed_in(
                &grant_bytes("other", "public-other-account"),
                OTHER_KEY,
            )?)
        },
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(signed_in.session.issued_account_key() == Some(&other));
    let document = stored(&mut store);
    assert!(contains(&document, OTHER_KEY) && !contains(&document, KEY));
    sign_out_with(&mut store, &mut |a| Ok(receipt(a))).unwrap();
    let document = stored(&mut store);
    assert!(!contains(&document, OTHER_KEY) && !contains(&document, KEY));
    operate(&mut store, |archive, _| {
        assert!(archive.profile_account()?.is_none());
        assert!(archive.account_key_for_disclosure().err() == Some(Failure::InvalidState));
        Ok(())
    })
    .unwrap();
}

#[test]
fn interactive_publication_requires_its_key_and_refresh_cannot_change_it() {
    let (_root, mut store, _) = fixture();
    let rejected = issue(
        &mut store,
        Replacement::Interactive,
        deployment(),
        |_| Ok(refreshed("keyless", "public-account")),
        &mut |_| panic!("an unpublished grant needs explicit recovery"),
    )
    .err()
    .unwrap();
    assert!(rejected.failure == Failure::InvalidState && rejected.unrecorded.is_none());
    let mut retired = Vec::new();
    recover_with(&mut store, &mut |a| {
        retired.push(a.token.as_str().to_owned());
        Ok(receipt(a))
    })
    .unwrap();
    assert!(retired == ["public-keyless-access", "public-keyless-refresh"]);
    install(&mut store, "old");
    let rejected = issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |_| {
            Ok(cloud::IssuedGrant::fixture_signed_in(
                &grant_bytes("changed-key", "public-account"),
                OTHER_KEY,
            )?)
        },
        &mut |_| panic!("an unpublished grant needs explicit recovery"),
    )
    .err()
    .unwrap();
    assert!(rejected.failure == Failure::InvalidState);
    recover_with(&mut store, &mut |a| Ok(receipt(a))).unwrap();
    // The abandoned rotation retired the whole family: sign in again.
    operate(&mut store, |archive, _| {
        assert!(archive.current.is_none());
        Ok(())
    })
    .unwrap();
    install(&mut store, "stored");
    let original = stored(&mut store);
    for (from, to) in [
        (
            "\"accountKey\":\"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7\"",
            "\"accountKey\":\"7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7\"",
        ),
        (
            "\"accountKey\":\"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7\"",
            "\"accountKey\":\"7KQF9M2XR4TDH8WBZN3CP6YE1AQ8\"",
        ),
        (
            "\"accountKey\":\"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7\"",
            "\"email\":\"public@example.test\"",
        ),
    ] {
        let text = String::from_utf8(original.clone()).unwrap();
        assert!(text.contains(from));
        let changed = text.replace(from, to);
        store
            .transaction(|owner| {
                let before = owner.read(Slot::Credentials)?.unwrap();
                owner.replace(Slot::Credentials, Some(&before), Some(changed.as_bytes()))?;
                assert!(Archive::load(owner).err() == Some(Failure::InvalidState));
                owner.replace(Slot::Credentials, Some(changed.as_bytes()), Some(&original))
            })
            .unwrap();
    }
}

#[test]
fn creation_key_and_envelope_are_checked_only_after_the_pair_is_journaled() {
    for key in [
        serde_json::json!("7KQF9M2XR4TDH8WBZN3CP6YE1AQ8"),
        serde_json::json!("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7"),
        serde_json::json!(null),
    ] {
        let (_root, mut store, _) = fixture();
        let rejected = create_account_with(
            &mut store,
            deployment(),
            |_| Ok(creation("orphan", "public-account", key.clone())),
            &mut |_| panic!("an unpublished grant needs explicit recovery"),
        )
        .err()
        .unwrap();
        assert!(rejected.failure == Failure::Cloud(cloud::Failure::InvalidResponse));
        assert!(rejected.unrecorded.is_none());
        let mut retired = Vec::new();
        recover_with(&mut store, &mut |a| {
            retired.push((a.token.as_str().to_owned(), a.refresh));
            Ok(receipt(a))
        })
        .unwrap();
        assert!(
            retired
                == [
                    ("public-orphan-access".into(), false),
                    ("public-orphan-refresh".into(), true)
                ]
        );
        operate(&mut store, |archive, _| {
            assert!(archive.current.is_none() && archive.pending.is_none());
            Ok(())
        })
        .unwrap();
    }
}

#[test]
fn retired_email_schema_requires_sign_in_again_and_is_replaced_before_issuance() {
    for pending in [false, true] {
        let (_root, mut store, _) = fixture();
        let session = serde_json::json!({
            "deployment":{"server":"https://cloud.example.test","instance":Uuid::from_u128(1)},
            "pair":{"access":"public-retired-access","refresh":"public-retired-refresh"},
            "account":"public-retired-account","email":"retired@example.test","expiresAt":1000
        });
        let pending_value = pending.then(|| {
            serde_json::json!({
                "kind":"refresh","deployment":session["deployment"],"previous":session,
                "issued":null,"published":false,"cleaning":false,"acknowledged":0
            })
        });
        let retired = serde_json::to_vec(&serde_json::json!({
            "schema":1,"generation":5,"current":session,"pending":pending_value
        }))
        .unwrap();
        store
            .transaction(|owner| owner.replace(Slot::Credentials, None, Some(&retired)))
            .unwrap();
        operate(&mut store, |archive, _| {
            assert!(archive.current.is_none() && archive.pending.is_none());
            assert!(archive.profile_account()?.is_none());
            assert!(archive.saved_deployment()?.is_none());
            assert!(archive.generation == 5 && archive.retired);
            Ok(())
        })
        .unwrap();
        recover_with(&mut store, &mut |_| {
            panic!("a retired email session is never sent anywhere")
        })
        .unwrap();
        let document = stored(&mut store);
        let value = canonical::parse(&document).unwrap();
        let top = value.as_object().unwrap();
        assert!(top["schema"].as_int().unwrap() == 2 && top["generation"].as_int().unwrap() == 5);
        assert!(!contains(&document, "email") && !contains(&document, "public-retired"));
        let live = issue(
            &mut store,
            Replacement::Interactive,
            deployment(),
            |_| Ok(grant("after-retirement", "public-account")),
            &mut |a| Ok(receipt(a)),
        )
        .unwrap_or_else(|e| panic!("{:?}", e.failure));
        assert!(live.account_display().unwrap() == display("public-account"));
        operate(&mut store, |archive, _| {
            assert!(archive.generation == 6);
            Ok(())
        })
        .unwrap();
    }
}

#[test]
fn owner_authorized_key_disclosure_is_bound_to_the_exact_saved_session() {
    use crate::{
        desktop::{SessionState, SessionWitness},
        local_auth::{self, Gate, Purpose},
    };
    let (_root, mut store, _) = fixture();
    assert!(prepare_account_key_disclosure(&mut store).err() == Some(Failure::InvalidState));
    install(&mut store, "disclosed");
    let mut gate = Gate::new();
    gate.set_foreground(true);
    let permit = |gate: &mut Gate, target: local_auth::Target| {
        let request = gate
            .begin(target, SessionWitness::test(SessionState::Unlocked, 1))
            .unwrap();
        gate.accept(local_auth::authenticate_fixture(request).unwrap())
            .unwrap()
    };
    let before = stored(&mut store);
    let target = prepare_account_key_disclosure(&mut store).unwrap();
    assert!(target.purpose() == Purpose::RevealAccountKey);
    let disclosure = reveal_account_key(&mut store, permit(&mut gate, target.clone())).unwrap();
    assert!(disclosure.valid());
    assert!(disclosure.display().unwrap().as_str() == "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7");
    // Backgrounding, lock or cancellation revoke an already drawn presentation.
    gate.set_foreground(false);
    assert!(!disclosure.valid());
    assert!(
        disclosure.display().err() == Some(Failure::Authentication(local_auth::Failure::Cancelled))
    );
    gate.set_foreground(true);
    assert!(stored(&mut store) == before);
    // A rotation changes the credential generation; an older permit discloses nothing.
    let stale = permit(&mut gate, target);
    issue(
        &mut store,
        Replacement::Refresh,
        deployment(),
        |_| Ok(refreshed("rotated", "public-account")),
        &mut |a| Ok(receipt(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(
        reveal_account_key(&mut store, stale).err()
            == Some(Failure::Authentication(local_auth::Failure::WrongTarget))
    );
    let target = prepare_account_key_disclosure(&mut store).unwrap();
    let signed_out = permit(&mut gate, target);
    sign_out_with(&mut store, &mut |a| Ok(receipt(a))).unwrap();
    assert!(reveal_account_key(&mut store, signed_out).err() == Some(Failure::InvalidState));
    assert!(prepare_account_key_disclosure(&mut store).err() == Some(Failure::InvalidState));
}

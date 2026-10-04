use crate::{cloud::*, crypto::RootKey, journal::Scope, model::Library, receiver::Owner, sync};
use serde_json::{Value, json};
use uuid::Uuid;
#[test]
#[ignore = "Opt-in disposable stateful integration fixture"]
fn audit_stateful_fault() {
    let c: Value =
        serde_json::from_slice(&std::fs::read("/root/snippets-stateful-config.json").unwrap())
            .unwrap();
    let stage = c["stage"].as_str().unwrap();
    let root_path = format!("/root/snippets-stateful-{}", c["run"].as_str().unwrap());
    let url = ServerURL::parse(c["origin"].as_str().unwrap()).unwrap();
    let client = CloudClient::discover(url.clone()).unwrap();
    let token = Credential::new(c["token"].as_str().unwrap().into()).unwrap();
    let space = client
        .observe_space(
            &token,
            Uuid::parse_str(c["space"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
    let (m, d) = space.scope.identities(&url);
    let scope = Scope {
        membership: m.clone(),
        dataset: d.clone(),
    };
    let mut t = client.clone().admit(token, space, &m, &d).unwrap();
    let key = RootKey::from_bytes(&[0x42; 32]).unwrap();
    let salt = [0x24; 32];
    let mut library = Library::open(root_path.clone().into()).unwrap();
    let synchronize = |library: &Library, t: &mut BoundTransport| {
        let guard = || {
            if stage == "switch"
                && std::path::Path::new(&format!("{root_path}/switch-now")).exists()
            {
                Err(crate::receiver::Failure::SessionChanged)
            } else {
                Ok(())
            }
        };
        let owner = Owner {
            library,
            scope: &scope,
            key_epoch: 1,
            checkpoint_key: &key,
            checkpoint_salt: &salt,
            wire_key: &key,
            wire_salt: &salt,
            device: Some("a11d1701"),
            vault_keys: None,
            validate_session: &guard,
        };
        for turn in 0..12 {
            let attempt = owner.synchronize(t, sync::Limits::DEFAULT);
            if stage == "switch" {
                assert!(matches!(
                    attempt,
                    Err(crate::receiver::Failure::SessionChanged)
                ));
                std::fs::write(format!("{root_path}/switch-completed"), b"done").unwrap();
                return;
            }
            let result = attempt.unwrap();
            if result.status == sync::Status::Current {
                return;
            }
            if stage == "review-keep"
                && result.status == sync::Status::Receiving(crate::receiver::Status::DeletionReview)
            {
                let review = owner.prepare_deletion_review(t).unwrap();
                assert!(!review.summary().secure);
                owner
                    .decide_deletion_review(t, review, crate::deletion_review::Choice::Keep)
                    .unwrap();
            } else {
                assert!(
                    matches!(result.status, sync::Status::MoreWork(_)),
                    "unexpected bounded sync status: {:?}",
                    result.status
                );
            }
            assert!(turn < 11, "sync did not settle within bounded retries");
        }
    };
    if stage == "prepare" {
        synchronize(&library, &mut t);
        library.reload().unwrap();
        assert_eq!(library.snippets.len(), 3);
        for keyword in ["race", "fields"] {
            let old = library
                .snippets
                .iter()
                .find(|s| s.keyword == keyword)
                .unwrap()
                .clone();
            let mut s = old.clone();
            if keyword == "race" {
                s.content = "audit-concurrent-linux".into();
            } else {
                s.content = "audit-field-linux".into();
            }
            library.save(s, Some(&old)).unwrap();
        }
    } else {
        if stage == "crash" || stage == "switch" {
            let old = library
                .snippets
                .iter()
                .find(|s| s.keyword == "fields")
                .unwrap()
                .clone();
            let mut s = old.clone();
            s.content = if stage == "switch" {
                "audit-account-switch-linux".into()
            } else {
                "audit-crash-linux".into()
            };
            library.save(s, Some(&old)).unwrap();
        }
        synchronize(&library, &mut t);
        library.reload().unwrap();
    }
    if stage == "switch" {
        let next = Credential::new(c["nextToken"].as_str().unwrap().into()).unwrap();
        assert!(
            client
                .observe_space(
                    &next,
                    Uuid::parse_str(c["space"].as_str().unwrap()).unwrap()
                )
                .is_err()
        );
        let next_space = client
            .observe_space(
                &next,
                Uuid::parse_str(c["nextSpace"].as_str().unwrap()).unwrap(),
            )
            .unwrap();
        let (bm, bd) = next_space.scope.identities(&url);
        let mut other = client.admit(next, next_space, &bm, &bd).unwrap();
        assert!(other.fetch_page(None).unwrap().records.is_empty());
    }
    let mut snapshot=library.snippets.iter().map(|s|{let mut tags=s.tags.clone();tags.sort();json!({"id":s.id.to_string(),"keyword":s.keyword,"name":s.name,"content":s.content,"tags":tags,"isPinned":s.is_pinned,"isEnabled":s.is_enabled})}).collect::<Vec<_>>();
    snapshot.sort_by_key(|s| s["id"].as_str().unwrap().to_owned());
    std::fs::write(
        format!("{root_path}/audit-snapshot.json"),
        serde_json::to_vec(&snapshot).unwrap(),
    )
    .unwrap();
}

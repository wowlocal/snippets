use super::*;
use crate::desktop::{SessionState, SessionWitness};
struct Desktop {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    witness: SessionWitness,
}
impl Drop for Desktop {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Release);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}
fn authorization() -> (Authorization, Desktop) {
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let ending = stop.clone();
    let observed = witness.clone();
    let thread = std::thread::spawn(move || {
        while !ending.load(std::sync::atomic::Ordering::Acquire) {
            observed.test_observe(SessionState::Unlocked);
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    });
    (
        Authorization::new(witness.clone()).unwrap(),
        Desktop {
            stop,
            thread: Some(thread),
            witness,
        },
    )
}
fn request(command: &str, keyword: &str, bytes: usize) -> Header {
    Header {
        v: control::PROTOCOL,
        nonce: Uuid::new_v4(),
        command: command.into(),
        identifier: (command == "reveal").then(|| keyword.into()),
        addition: (command == "add-secure").then(|| control::Addition {
            name: "Public CLI entry".into(),
            keyword: keyword.into(),
            tags: vec!["public".into()],
            is_enabled: true,
            is_pinned: false,
        }),
        bytes,
    }
}
#[test]
fn fresh_creation_seals_input_and_reveal_returns_exact_body_without_unlocking_editor() {
    let (_temp, library, mut vault) = super::super::tests::setup();
    let used = vault.session.as_ref().unwrap().used;
    let public = b"Public fictional CLI body \n";
    let captured = Captured::capture(
        library.root.clone(),
        &request("add-secure", "public-cli", public.len()),
        Zeroizing::new(public.to_vec()),
        Lease::fixture(|| Ok(())),
    )
    .unwrap();
    let preview = captured.preview();
    assert_eq!(preview.metadata.keyword, "public-cli");
    assert!(preview.passphrase && preview.recovery);
    let (auth, _desktop) = authorization();
    let reply = captured
        .complete(Zeroizing::new("Café public fixture".into()), false, &auth)
        .unwrap();
    assert!(reply.header.created_id.is_some());
    assert!(reply.body.is_empty());
    assert_eq!(vault.session.as_ref().unwrap().used, used);
    let bytes = std::fs::read(library.root.join("Vault/vault.json")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("Public fictional CLI body"));
    vault.lock();
    assert!(!vault.is_unlocked());
    let captured = Captured::capture(
        library.root.clone(),
        &request("reveal", "public-cli", 0),
        Zeroizing::new(vec![]),
        Lease::fixture(|| Ok(())),
    )
    .unwrap();
    let (auth, _desktop) = authorization();
    let reply = captured
        .complete(Zeroizing::new("Café public fixture".into()), false, &auth)
        .unwrap();
    assert_eq!(&*reply.body, public);
    assert!(!vault.is_unlocked());
    assert_eq!(
        std::fs::read(library.root.join("Vault/vault.json")).unwrap(),
        bytes
    );
}

#[test]
fn wrong_credentials_revocation_lock_busy_and_changed_sources_never_author_or_disclose() {
    for changed in 0..5 {
        let (_temp, library, _vault) = super::super::tests::setup();
        let bytes = std::fs::read(library.root.join("Vault/vault.json")).unwrap();
        let header = request("add-secure", "public-cli", 6);
        let captured = Captured::capture(
            library.root.clone(),
            &header,
            Zeroizing::new(b"Public".to_vec()),
            Lease::fixture(|| Ok(())),
        )
        .unwrap();
        let (auth, desktop) = authorization();
        let mut held = None;
        match changed {
            0 => (),
            1 => auth.cancel(),
            2 => {
                desktop
                    .stop
                    .store(true, std::sync::atomic::Ordering::Release);
                desktop.witness.test_observe(SessionState::Locked);
            }
            3 => {
                model::atomic_write(&library.root.join("Vault/vault.json"), &bytes).unwrap();
            }
            _ => held = Some(library.lock().unwrap()),
        }
        let password = if changed == 0 {
            "Wrong public credential"
        } else {
            "Café public fixture"
        };
        let result = captured.complete(Zeroizing::new(password.into()), false, &auth);
        assert!(
            result.err()
                == Some(match changed {
                    0 => Status::Locked,
                    1 | 2 => Status::Denied,
                    _ => Status::Refused,
                })
        );
        drop(held);
        assert_eq!(
            std::fs::read(library.root.join("Vault/vault.json")).unwrap(),
            bytes
        );
    }
}
#[test]
fn cross_store_duplicates_and_missing_records_are_refused_without_upserts() {
    for secure in [false, true] {
        let (_temp, mut library, vault) = super::super::tests::setup();
        let keyword = if secure {
            vault.document.as_ref().unwrap().records[0]
                .metadata
                .keyword
                .clone()
        } else {
            let mut s = Snippet::new("Public ordinary", "Public ordinary body");
            s.keyword = "public-duplicate".into();
            library.save(s, None).unwrap();
            "public-duplicate".into()
        };
        let bytes = std::fs::read(library.root.join("Vault/vault.json")).unwrap();
        let captured = Captured::capture(
            library.root.clone(),
            &request("add-secure", &keyword, 6),
            Zeroizing::new(b"Public".to_vec()),
            Lease::fixture(|| Ok(())),
        )
        .unwrap();
        let (auth, _desktop) = authorization();
        assert!(
            captured
                .complete(Zeroizing::new("Café public fixture".into()), false, &auth)
                .is_err()
        );
        assert_eq!(
            std::fs::read(library.root.join("Vault/vault.json")).unwrap(),
            bytes
        );
        assert!(
            Captured::capture(
                library.root,
                &request("reveal", "public-missing", 0),
                Zeroizing::new(vec![]),
                Lease::fixture(|| Ok(()))
            )
            .is_err()
        );
    }
}

#[test]
fn decrypted_reply_remains_bound_to_exact_source_and_primary_readiness_until_delivery() {
    for replacement in [false, true] {
        let (_temp, library, vault) = super::super::tests::setup();
        let keyword = vault.document.as_ref().unwrap().records[0]
            .metadata
            .keyword
            .clone();
        let captured = Captured::capture(
            library.root.clone(),
            &request("reveal", &keyword, 0),
            Zeroizing::new(vec![]),
            Lease::fixture(|| Ok(())),
        )
        .unwrap();
        let (auth, _desktop) = authorization();
        let reply = captured
            .complete(Zeroizing::new("Café public fixture".into()), false, &auth)
            .unwrap();
        let delivery = reply.delivery.as_ref().unwrap();
        delivery.validate().unwrap();
        if replacement {
            let path = library.root.join("Vault/vault.json");
            let bytes = std::fs::read(&path).unwrap();
            model::atomic_write(&path, &bytes).unwrap();
        } else {
            std::fs::create_dir(library.root.join("Backups")).unwrap();
            model::atomic_write(
                &library.root.join("Backups/restore.pending"),
                b"Public opaque marker",
            )
            .unwrap();
        }
        assert!(delivery.validate().is_err());
    }
}

#[cfg(feature = "desktop")]
#[test]
fn socket_worker_keeps_submitted_bodies_out_of_ui_notices_and_returns_exact_approved_frames() {
    use crate::control::{
        ReplyHeader, read_body, read_header,
        server::{Command, Notice, Offer},
        write_all, write_header,
    };
    use std::{os::unix::net::UnixStream, sync::mpsc, time::Duration};
    let (_temp, library, mut vault) = super::super::tests::setup();
    vault.lock();
    let public = "Public fictional socket body 🙂\n".as_bytes();
    for command in ["add-secure", "reveal", "status", "denied"] {
        let header = request(
            if command == "denied" {
                "reveal"
            } else {
                command
            },
            "public-socket",
            if command == "add-secure" {
                public.len()
            } else {
                0
            },
        );
        let (client, server) = UnixStream::pair().unwrap();
        client.set_nonblocking(true).unwrap();
        let mut client = crate::control::local_io(client);
        server.set_nonblocking(true).unwrap();
        let (sender, receiver) = mpsc::sync_channel::<Offer>(1);
        let root = library.root.clone();
        let worker = std::thread::spawn(move || {
            crate::control::server::serve(server, root, Lease::fixture(|| Ok(())), &sender)
        });
        write_header(&mut client, &header, &|| Ok(())).unwrap();
        if command == "add-secure" {
            write_all(&mut client, public, &|| Ok(())).unwrap();
        }
        let offer = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(offer.header.bytes, header.bytes);
        assert!(
            !serde_json::to_string(&offer.header)
                .unwrap()
                .contains("Public fictional socket body")
        );
        let desktop = match command {
            "status" => {
                offer.commands.send(Command::State(false)).unwrap();
                None
            }
            "denied" => {
                offer.commands.send(Command::Deny).unwrap();
                None
            }
            _ => {
                offer.commands.send(Command::Prepare).unwrap();
                let Notice::Prepared(preview) =
                    offer.notices.recv_timeout(Duration::from_secs(2)).unwrap()
                else {
                    panic!("public preview");
                };
                assert_eq!(preview.metadata.keyword, "public-socket");
                let (authorization, desktop) = authorization();
                offer
                    .commands
                    .send(Command::Authenticate {
                        password: Zeroizing::new("Café public fixture".into()),
                        recovery: false,
                        authorization,
                    })
                    .unwrap();
                Some(desktop)
            }
        };
        let reply: ReplyHeader = read_header(&mut client, &|| Ok(())).unwrap();
        assert_eq!(reply.nonce, header.nonce);
        assert_eq!(
            reply.status,
            if command == "denied" {
                Status::Denied
            } else {
                Status::Ok
            }
        );
        let bytes = read_body(&mut client, reply.bytes, &|| Ok(())).unwrap();
        if command == "reveal" {
            assert_eq!(&*bytes, public);
        } else {
            assert!(bytes.is_empty());
        }
        if command == "status" {
            assert_eq!(reply.unlocked, Some(false));
            assert_eq!(reply.secure_count, Some(2));
        }
        if command == "add-secure" {
            assert!(reply.created_id.is_some());
        }
        let Notice::Finished { status, created } =
            offer.notices.recv_timeout(Duration::from_secs(2)).unwrap()
        else {
            panic!("completion receipt");
        };
        assert_eq!(status, reply.status);
        assert_eq!(created, reply.created_id);
        worker.join().unwrap().unwrap();
        drop(desktop);
        assert!(!vault.is_unlocked());
    }
    assert!(
        !String::from_utf8_lossy(&std::fs::read(library.root.join("Vault/vault.json")).unwrap())
            .contains("Public fictional socket body")
    );
}

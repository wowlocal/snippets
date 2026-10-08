use super::*;
use std::{
    io::Cursor,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
fn header(command: &str) -> Header {
    Header {
        v: PROTOCOL,
        nonce: Uuid::from_u128(1),
        command: command.into(),
        identifier: None,
        addition: None,
        bytes: 0,
    }
}
#[test]
fn closed_bounded_metadata_frames_never_serialize_secret_payloads() {
    let mut h = header("add-secure");
    h.bytes = 6;
    h.addition = Some(Addition {
        name: "Public name".into(),
        keyword: "public".into(),
        tags: vec!["public".into()],
        is_enabled: true,
        is_pinned: false,
    });
    h.validate().unwrap();
    let mut stream = Cursor::new(Vec::new());
    write_header(&mut stream, &h, &|| Ok(())).unwrap();
    assert!(!String::from_utf8_lossy(stream.get_ref()).contains("secret"));
    stream.set_position(0);
    let decoded: Header = read_header(&mut stream, &|| Ok(())).unwrap();
    assert_eq!(decoded.bytes, 6);
    decoded.validate().unwrap();
    let mut value = serde_json::to_value(&h).unwrap();
    value["body"] = serde_json::json!("forbidden");
    assert!(serde_json::from_value::<Header>(value).is_err());
    for count in [0, MAX_HEADER + 1, usize::MAX] {
        let mut stream = Cursor::new((count as u32).to_be_bytes().to_vec());
        assert!(read_header::<Header>(&mut stream, &|| Ok(())).is_err());
    }
    let failure = Reply::status(h.nonce, Status::Denied);
    assert!(failure.body.is_empty());
    assert!(
        !serde_json::to_string(&failure.header)
            .unwrap()
            .contains("Public")
    );
}
#[test]
fn malformed_wrong_role_and_oversize_requests_are_refused_before_body_read() {
    let mut h = header("status");
    h.validate().unwrap();
    h.bytes = 1;
    assert!(h.validate().is_err());
    h = header("reveal");
    assert!(h.validate().is_err());
    h.identifier = Some("public".into());
    h.validate().unwrap();
    h.addition = Some(Addition {
        name: "".into(),
        keyword: "public".into(),
        tags: vec![],
        is_enabled: true,
        is_pinned: false,
    });
    assert!(h.validate().is_err());
    let mut addition = h.addition.take().unwrap();
    addition.tags = vec!["public".into(); 65];
    assert!(addition.validate().is_err());
    addition.tags.clear();
    addition.keyword = "\\ ".into();
    assert!(addition.validate().is_err());
    for bytes in [vec![0], vec![0xff], vec![b'a'; model::MAX_BODY_BYTES + 1]] {
        assert!(read_body(&mut Cursor::new(bytes.clone()), bytes.len(), &|| Ok(())).is_err());
    }
}
#[test]
fn partial_reads_writes_and_revocation_preserve_full_utf8_without_retrying_secrets() {
    struct Chunks(Cursor<Vec<u8>>);
    impl Read for Chunks {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            let n = bytes.len().min(3);
            self.0.read(&mut bytes[..n])
        }
    }
    impl Write for Chunks {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.write(&bytes[..bytes.len().min(2)])
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let public = "Public 🙂中é\n".repeat(300);
    let mut stream = Chunks(Cursor::new(Vec::new()));
    write_all(&mut stream, public.as_bytes(), &|| Ok(())).unwrap();
    stream.0.set_position(0);
    assert_eq!(
        &*read_body(&mut stream, public.len(), &|| Ok(())).unwrap(),
        public.as_bytes()
    );
    let count = AtomicUsize::new(0);
    let mut stream = Chunks(Cursor::new(Vec::new()));
    assert!(
        write_all(
            &mut stream,
            public.as_bytes(),
            &|| if count.fetch_add(1, Ordering::SeqCst) == 3 {
                Err(CLOSED)
            } else {
                Ok(())
            }
        )
        .is_err()
    );
    assert_eq!(stream.0.get_ref().len(), 6);
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop.clone();
    let lease = Lease::fixture(move || {
        if stopped.load(Ordering::Acquire) {
            Err(CLOSED)
        } else {
            Ok(())
        }
    });
    lease.check().unwrap();
    assert_eq!(lease.caller(), "Public fixture requester");
    stop.store(true, Ordering::Release);
    assert!(lease.check().is_err());
}
#[test]
fn runtime_endpoint_is_private_root_bound_and_never_truncated() {
    let runtime = tempfile::tempdir().unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(runtime.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let first = endpoint_at(Path::new("/public/library-one"), runtime.path()).unwrap();
    let second = endpoint_at(Path::new("/public/library-two"), runtime.path()).unwrap();
    assert_ne!(first, second);
    assert!(!first.exists());
    assert!(!runtime.path().join("snippets-control").exists());
    use std::os::unix::fs::symlink;
    let link = runtime.path().join("public-link");
    symlink(runtime.path(), &link).unwrap();
    assert!(endpoint_at(Path::new("/public"), &link).is_err());
    let long = runtime.path().join("public-long-directory".repeat(5));
    std::fs::create_dir(&long).unwrap();
    std::fs::set_permissions(&long, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(endpoint_at(Path::new("/public"), &long).is_err());
    std::fs::set_permissions(runtime.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(endpoint_at(Path::new("/public"), runtime.path()).is_err());
}

#[test]
fn client_binds_reply_nonce_role_and_status_before_reading_or_returning_any_body() {
    use std::os::unix::net::UnixStream;
    for case in 0..5 {
        let (stream, server) = UnixStream::pair().unwrap();
        stream.set_nonblocking(true).unwrap();
        let mut server = local_io(server);
        let worker = std::thread::spawn(move || {
            let request: Header = read_header(&mut server, &|| Ok(())).unwrap();
            let mut reply = Reply::status(request.nonce, Status::Ok);
            match case {
                0 => reply.header.nonce = Uuid::new_v4(),
                1 => reply.header.created_id = Some(Uuid::new_v4()),
                2 => {
                    reply.header.status = Status::Denied;
                    reply.header.bytes = 6;
                }
                3 => reply.header.bytes = model::MAX_BODY_BYTES + 1,
                _ => reply.header.bytes = "Public 🙂\n".len(),
            }
            write_header(&mut server, &reply.header, &|| Ok(())).unwrap();
            if case == 4 {
                write_all(&mut server, "Public 🙂\n".as_bytes(), &|| Ok(())).unwrap();
            }
        });
        let client = Client {
            stream: local_io(stream),
            lease: Lease::fixture(|| Ok(())),
        };
        match client.reveal("public".into()) {
            Ok(Outcome::Revealed(body)) if case == 4 => {
                assert_eq!(&*body, "Public 🙂\n".as_bytes())
            }
            Err(_) if case != 4 => (),
            _ => panic!("unexpected reply acceptance"),
        }
        worker.join().unwrap();
    }
}

#[test]
fn configuration_requests_cannot_carry_snippet_metadata_or_secret_bytes() {
    for command in [
        ExpansionCommand::Status,
        ExpansionCommand::Enable,
        ExpansionCommand::Disable,
        ExpansionCommand::EnableSuggestions,
        ExpansionCommand::DisableSuggestions,
        ExpansionCommand::Retry,
    ] {
        let mut request = header(command.wire());
        request.validate().unwrap();
        request.bytes = 1;
        assert!(request.validate().is_err());
        request.bytes = 0;
        request.identifier = Some("public".into());
        assert!(request.validate().is_err());
        request.identifier = None;
        request.addition = Some(Addition {
            name: String::new(),
            keyword: "public".into(),
            tags: vec![],
            is_enabled: true,
            is_pinned: false,
        });
        assert!(request.validate().is_err());
    }
    assert!(ExpansionCommand::from_wire("expansion-enable-unknown").is_none());
}

#[test]
fn configuration_replies_are_closed_and_legacy_servers_are_reported() {
    use std::os::unix::net::UnixStream;
    for case in 0..5 {
        let (stream, server) = UnixStream::pair().unwrap();
        stream.set_nonblocking(true).unwrap();
        let mut server = local_io(server);
        let worker = std::thread::spawn(move || {
            let request: Header = read_header(&mut server, &|| Ok(())).unwrap();
            assert_eq!(request.command, "expansion-status");
            let mut reply = Reply::status(
                request.nonce,
                if case == 4 {
                    Status::Unsupported
                } else {
                    Status::Ok
                },
            );
            let mut payload =
                serde_json::json!({"enabled":true,"suggestions":true,"state":"waitingForField"});
            match case {
                1 => payload["message"] = serde_json::json!("unapproved field"),
                2 => payload["enabled"] = serde_json::json!(false),
                3 => reply.header.unlocked = Some(true),
                _ => (),
            }
            if case != 4 {
                reply.body = Zeroizing::new(serde_json::to_vec(&payload).unwrap());
                reply.header.bytes = reply.body.len();
            }
            write_header(&mut server, &reply.header, &|| Ok(())).unwrap();
            let _ = write_all(&mut server, &reply.body, &|| Ok(()));
        });
        let client = Client {
            stream: local_io(stream),
            lease: Lease::fixture(|| Ok(())),
        };
        match client.expansion(ExpansionCommand::Status) {
            Ok(Outcome::Expansion(settings)) if case == 0 => {
                assert!(settings.enabled && settings.suggestions);
                assert_eq!(settings.state, ExpansionState::WaitingForField);
            }
            Ok(Outcome::Rejected(Status::Unsupported)) if case == 4 => (),
            Err(_) if (1..=3).contains(&case) => (),
            _ => panic!("invalid configuration response accepted"),
        }
        worker.join().unwrap();
    }
}

#[cfg(feature = "desktop")]
#[test]
fn configuration_server_routes_to_primary_and_returns_exact_saved_state() {
    use std::os::unix::net::UnixStream;
    let root = tempfile::tempdir().unwrap();
    let (stream, server_stream) = UnixStream::pair().unwrap();
    stream.set_nonblocking(true).unwrap();
    server_stream.set_nonblocking(true).unwrap();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let path = root.path().to_owned();
    let server = std::thread::spawn(move || {
        server::serve(server_stream, path, Lease::fixture(|| Ok(())), &sender)
    });
    let client = std::thread::spawn(move || {
        Client {
            stream: local_io(stream),
            lease: Lease::fixture(|| Ok(())),
        }
        .expansion(ExpansionCommand::Enable)
    });
    let offer = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(offer.header.command, "expansion-enable");
    crate::inline_settings::Preference::enable_with_suggestions(root.path()).unwrap();
    offer
        .commands
        .send(server::Command::Expansion(ExpansionSettings {
            enabled: true,
            suggestions: true,
            state: ExpansionState::Starting,
        }))
        .unwrap();
    assert!(matches!(
        client.join().unwrap().unwrap(),
        Outcome::Expansion(ExpansionSettings {
            enabled: true,
            suggestions: true,
            state: ExpansionState::Starting
        })
    ));
    server.join().unwrap().unwrap();
    let saved = crate::inline_settings::Preference::read(root.path()).unwrap();
    assert!(saved.enabled && saved.suggestions);
    assert!(!root.path().join("snippets.json").exists());
    assert!(!root.path().join("Vault").exists());
}

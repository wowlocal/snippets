//! Git sync: layout/identity vectors, recovery envelopes, and multi-device
//! cycles through the real `git` against disposable bare repositories. The
//! default tests reach repositories through a stand-in ssh program (no
//! network, no keys, no agent); the HTTP and real-sshd variants are ignored
//! here and run only through tests/git-sync-live.sh with private fixtures.
use crate::{
    bootstrap::Bundle,
    clock::Hlc,
    cloud,
    deletion_review::{Choice, Kind},
    git_layout::{self, Mode, Position},
    git_location::{Location, Remote, valid_branch},
    git_plain,
    git_recovery::{self, Kit},
    git_repo,
    git_setup::{self, Environment, Failure, Form, State, SyncState},
    git_transport,
    model::{Library, Snippet},
    receiver,
    secret_store::{Store, tests::Memory},
    sender,
    wire::{Envelope, WireRecord},
};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
};
use uuid::Uuid;
use zeroize::Zeroizing;

// MARK: - Locations and identities

fn canonical(text: &str) -> String {
    Location::parse(text, false).unwrap().canonical_identity()
}
#[test]
fn repository_identity_matches_the_apple_rule() {
    for text in [
        "git@github.com:me/lib.git",
        "ssh://git@GitHub.com:22/me/lib.git",
        "git+ssh://git@github.com/me/lib",
        "https://github.com/me/lib/",
        "https://GITHUB.com/me/lib.git",
        "github.com/me/lib",
        "  https://github.com/me/lib  ",
    ] {
        assert_eq!(canonical(text), "github.com/me/lib", "{text}");
    }
    // Path case is preserved; the path is percent-decoded; only one ".git" goes.
    assert_eq!(
        canonical("https://gitverse.ru/Me/Lib%20X.git"),
        "gitverse.ru/Me/Lib X"
    );
    assert_eq!(canonical("ssh://host/~/repo.git"), "host/~/repo");
    assert_eq!(canonical("host:~/repo.git"), "host/~/repo");
    assert_eq!(canonical("git@host:lib.git.git"), "host/lib.git");
    // ".git" is removed before trailing slashes, exactly as on Apple.
    assert_eq!(canonical("git@host:lib.git/"), "host/lib.git");
    assert_eq!(canonical("ssh://[::1]:2222/srv/lib.git"), "::1/srv/lib");
    // One percent-decoding pass; a '%' left after it is refused, as on Apple.
    assert_eq!(canonical("ssh://host/a%41b.git"), "host/aAb");
    for refused in ["git@host:li%41b", "ssh://host/a%2541", "git@host:100%"] {
        assert!(Location::parse(refused, false).is_err(), "{refused}");
    }
    assert_eq!(canonical("https://Example.com:8443/a/b"), "example.com/a/b");
    // Specs are normalized for storage and git; user and port are kept there.
    let spec = |t: &str| Location::parse(t, false).unwrap().spec();
    assert_eq!(
        spec("ssh://git@GitHub.com:22/me/lib.git"),
        "ssh://git@GitHub.com:22/me/lib.git"
    );
    assert_eq!(
        spec("git@github.com:me/lib.git"),
        "git@github.com:me/lib.git"
    );
    assert_eq!(
        spec("HTTPS://GitHub.com/me/lib/"),
        "https://github.com/me/lib"
    );
    assert_eq!(spec("github.com/me/lib"), "https://github.com/me/lib");
    assert!(
        Location::parse("git@github.com:me/lib.git", false)
            .unwrap()
            .is_ssh()
    );
    assert!(
        !Location::parse("github.com/me/lib", false)
            .unwrap()
            .is_ssh()
    );
}
#[test]
fn unsafe_or_ambiguous_locations_are_refused() {
    for text in [
        "",
        "-oProxyCommand=x:lib",
        "git@-host:lib",
        "git@.host:lib",
        "-user@host:lib",
        "git@host:-lib",
        "git@host:lib;rm",
        "git@host:li$b",
        "git@host:a/../b",
        "git@host:lib name",
        "ssh://host",
        "ssh://user:pw@host/lib",
        "ssh://host:0/lib",
        "ssh://host:70000/lib",
        "ssh://host/lib?x",
        "http://example.com/lib",
        "http://127.0.0.1/lib",
        "https://user:pw@github.com/me/lib",
        "https://github.com/me/lib?x=1",
        "https://github.com/me/lib#x",
        "https://github.com",
        "https://github.com/",
        "file:///tmp/lib.git",
        "ftp://host/lib",
    ] {
        assert!(Location::parse(text, false).is_err(), "{text:?}");
    }
    // Plain HTTP only to literal loopback addresses, only when a test
    // harness opts in: never a name that could resolve elsewhere.
    assert!(Location::parse("http://127.0.0.1:8080/lib.git", true).is_ok());
    assert!(Location::parse("http://[::1]:8080/lib.git", true).is_ok());
    for name in [
        "http://localhost/lib.git",
        "http://repo.localhost/lib.git",
        "http://example.com/lib.git",
        "http://127.0.0.1.example.com/lib.git",
    ] {
        assert!(Location::parse(name, true).is_err(), "{name}");
    }
    assert!(Location::parse("http://127.0.0.1:8080/lib.git", false).is_err());
}

#[test]
fn an_unsupported_ssh_fails_closed() {
    let fixture = Fixture::new();
    let old = fixture.directory.path().join("old-ssh");
    std::fs::write(
        &old,
        "#!/bin/sh\n[ \"$1\" = -V ] && { echo 'OpenSSH_8.6p1, old' >&2; exit 0; }\nexit 1\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut transport = git_transport::GitTransport::new(git_transport::Configuration {
        remote: Remote::new(Location::parse(&fixture.location(), false).unwrap(), "main").unwrap(),
        credential: None,
        cache: fixture.directory.path().join("cache-old"),
        expected_dataset: None,
        options: git_repo::Options {
            ssh_program: Some(old),
            ..Default::default()
        },
        now: git_transport::now,
        plain_key: None,
        expected_mode: None,
    })
    .unwrap();
    assert_eq!(
        transport.inspect().err(),
        Some(git_transport::Failure::Git(git_repo::Failure::SshTooOld))
    );
    assert_eq!(
        git_repo::Failure::SshTooOld.code(),
        "git_unsupported_ssh_version"
    );
}

/// A loopback HTTP server answering one connection per response, in order;
/// the requests' heads come back through the handle.
fn canned_server(responses: Vec<String>) -> (String, std::thread::JoinHandle<Vec<String>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let handle = std::thread::spawn(move || {
        use std::io::{Read, Write};
        let mut requests = Vec::new();
        for response in responses {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let mut request = Vec::new();
            let mut buffer = [0; 1024];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                match stream.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => request.extend_from_slice(&buffer[..n]),
                }
            }
            let _ = stream.write_all(response.as_bytes());
            requests.push(String::from_utf8_lossy(&request).into_owned());
        }
        requests
    });
    (format!("http://{address}/me/open.git"), handle)
}
fn http(status: &str, headers: &str) -> String {
    format!("HTTP/1.1 {status}\r\n{headers}Content-Length: 0\r\nConnection: close\r\n\r\n")
}
const ADVERTISED: &str = "Content-Type: application/x-git-upload-pack-advertisement\r\n";

/// Apple `visibility(of:)`: an anonymous smart-HTTP advertisement request.
/// 200 with the advertisement is public; 401, 403 or 404 private; anything
/// else unknown. Redirects only within the same origin, at most three; SSH
/// only at well-known forges.
#[test]
fn repository_visibility_is_public_private_or_unknown() {
    use git_setup::{Visibility, visibility};
    let probe = |responses: Vec<String>| {
        let (url, server) = canned_server(responses);
        let answer = visibility(&Location::parse(&url, true).unwrap(), true);
        (answer, server.join().unwrap())
    };
    let (answer, requests) = probe(vec![http("200 OK", ADVERTISED)]);
    assert_eq!(answer, Visibility::Public);
    let request = &requests[0];
    assert!(request.starts_with("GET /me/open.git/info/refs?service=git-upload-pack HTTP/1.1\r\n"));
    let lowered = request.to_ascii_lowercase();
    assert!(!lowered.contains("authorization") && !lowered.contains("cookie"));
    assert!(request.contains("git/2.0 (Snippets)"));
    for (status, expected) in [
        ("401 Unauthorized", Visibility::Private),
        ("403 Forbidden", Visibility::Private),
        ("404 Not Found", Visibility::Private),
        ("500 Internal Server Error", Visibility::Unknown),
        ("429 Too Many Requests", Visibility::Unknown),
    ] {
        assert_eq!(probe(vec![http(status, "")]).0, expected, "{status}");
    }
    // Dumb HTTP is not a public clone Snippets recognizes.
    assert_eq!(
        probe(vec![http("200 OK", "Content-Type: text/plain\r\n")]).0,
        Visibility::Unknown
    );
    // Same-origin redirects are followed, at most three.
    let to_self = "Location: /me/open.git/info/refs?service=git-upload-pack\r\n";
    let (answer, requests) = probe(vec![
        http("301 Moved Permanently", to_self),
        http("302 Found", to_self),
        http("307 Temporary Redirect", to_self),
        http("200 OK", ADVERTISED),
    ]);
    assert_eq!((answer, requests.len()), (Visibility::Public, 4));
    let (answer, requests) = probe(vec![http("302 Found", to_self); 4]);
    assert_eq!((answer, requests.len()), (Visibility::Unknown, 4));
    // A redirect to another origin is not followed.
    let (elsewhere, untouched) = canned_server(vec![http("200 OK", ADVERTISED)]);
    let away = format!("Location: {elsewhere}/info/refs?service=git-upload-pack\r\n");
    let (answer, requests) = probe(vec![http("302 Found", &away)]);
    assert_eq!((answer, requests.len()), (Visibility::Unknown, 1));
    drop(std::net::TcpStream::connect(
        elsewhere
            .trim_start_matches("http://")
            .split('/')
            .next()
            .unwrap(),
    ));
    assert!(
        untouched.join().unwrap()[0].is_empty(),
        "the other origin got no request"
    );
    // Nothing listening: unknown.
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/me/open.git", closed.local_addr().unwrap());
    drop(closed);
    assert_eq!(
        visibility(&Location::parse(&url, true).unwrap(), true),
        Visibility::Unknown
    );
    // SSH: only well-known forges, at their HTTPS address; any other SSH
    // host is unknown with no request.
    for (ssh, base) in [
        (
            "git@github.com:me/lib.git",
            Some("https://github.com/me/lib.git"),
        ),
        (
            "ssh://git@ssh.github.com:443/me/lib.git",
            Some("https://github.com/me/lib.git"),
        ),
        (
            "ssh://git@ssh.github.com/me/lib.git",
            Some("https://github.com/me/lib.git"),
        ),
        (
            "git@gitlab.com:group/lib.git",
            Some("https://gitlab.com/group/lib.git"),
        ),
        (
            "ssh://git@altssh.gitlab.com:443/group/lib.git",
            Some("https://gitlab.com/group/lib.git"),
        ),
        (
            "git@codeberg.org:me/lib.git",
            Some("https://codeberg.org/me/lib.git"),
        ),
        (
            "git@bitbucket.org:me/lib.git",
            Some("https://bitbucket.org/me/lib.git"),
        ),
        ("ssh://git@github.com:2222/me/lib.git", None),
        ("ssh://git@altssh.gitlab.com/group/lib.git", None),
        ("git@git.example.com:me/lib.git", None),
        ("ssh://git@host.example:2222/srv/lib.git", None),
    ] {
        let location = Location::parse(ssh, false).unwrap();
        assert_eq!(location.public_probe_base().as_deref(), base, "{ssh}");
        if base.is_none() {
            assert_eq!(visibility(&location, false), Visibility::Unknown);
        }
    }
    // The SSH check command, as Apple's `testCommand`.
    for (ssh, command) in [
        ("git@github.com:me/lib.git", "ssh -T git@github.com"),
        (
            "ssh://git@host.example:2222/srv/lib.git",
            "ssh -T -p 2222 git@host.example",
        ),
        ("ssh://host.example:22/lib", "ssh -T host.example"),
    ] {
        assert_eq!(
            Location::parse(ssh, false)
                .unwrap()
                .ssh_test_command()
                .as_deref(),
            Some(command)
        );
    }
    // One repository reached two ways (Apple `sameEndpoint`).
    let same = |a: &str, b: &str| {
        Location::parse(a, false)
            .unwrap()
            .same_endpoint(&Location::parse(b, false).unwrap())
    };
    assert!(same(
        "https://github.com/me/lib",
        "git@github.com:me/lib.git"
    ));
    assert!(same(
        "https://github.com/me/lib",
        "https://GitHub.com/me/lib.git/"
    ));
    assert!(!same(
        "https://github.com/me/lib",
        "https://github.com:8443/me/lib"
    ));
    assert!(!same("git@host.example:lib", "other@host.example:lib"));
    assert!(!same(
        "ssh://git@host.example/lib",
        "ssh://git@host.example:2222/lib"
    ));
    assert!(same(
        "ssh://git@host.example:22/lib",
        "git@host.example:lib"
    ));
    assert!(!same(
        "https://github.com/me/lib",
        "https://github.com/me/other"
    ));
}

/// Creating a plain-text library: public is refused, unknown needs the
/// user's word that the repository is private, and nothing is written first.
#[test]
fn plain_text_needs_a_private_repository() {
    let fixture = Fixture::new();
    let attempt = |response: String, confirmed: bool| {
        let (url, server) = canned_server(vec![response]);
        let mut device = fixture.device();
        device.environment.insecure_loopback = true;
        let form = Form {
            repository: url,
            branch: "main".into(),
            username: "tester".into(),
            token: Zeroizing::new("fixture-token".into()),
        };
        let failure = git_setup::create(
            &device.environment,
            &mut device.store,
            &form,
            Mode::PlainText,
            confirmed,
        )
        .err()
        .map(|(failure, code)| (failure, code.is_some()));
        let requests = server.join().unwrap();
        assert!(!requests[0].to_ascii_lowercase().contains("authorization"));
        let settings = git_setup::Settings::read(&device.environment.root).unwrap();
        (failure, settings.is_none())
    };
    assert_eq!(
        attempt(http("200 OK", ADVERTISED), true),
        (Some((Failure::PublicRepository, false)), true)
    );
    assert_eq!(
        attempt(http("500 Internal Server Error", ""), false),
        (Some((Failure::VisibilityUnknown, false)), true)
    );
    // With the user's word, creation goes on (and here fails later: the
    // canned server is no git host).
    let (failure, _) = attempt(http("500 Internal Server Error", ""), true);
    assert!(!matches!(
        failure,
        Some((Failure::VisibilityUnknown | Failure::PublicRepository, _)) | None
    ));
    assert_eq!(Failure::PublicRepository.code(), "public_repository");
    assert_eq!(Failure::VisibilityUnknown.code(), "visibility_unknown");
    assert_eq!(
        Failure::VisibilityUnknown.message(),
        "Snippets couldn’t check whether this repository is private. Create a plain-text library only if it is private: anyone who can read the repository can read your ordinary snippets."
    );
}

#[test]
fn tool_versions_and_host_help_follow_apple() {
    for (text, minimum, expected) in [
        ("2.32.0\n", (2, 32), true),
        ("2.47.1 (Apple Git-154)", (2, 32), true),
        ("2.31.8", (2, 32), false),
        ("3.0", (2, 32), true),
        ("9.6p1, OpenSSL 3.4.0", (8, 7), true),
        ("8.7p1 Ubuntu", (8, 7), true),
        ("8.6p1", (8, 7), false),
        ("", (2, 32), false),
        ("x.y", (2, 32), false),
    ] {
        assert_eq!(
            git_repo::version_at_least(text, minimum),
            expected,
            "{text:?}"
        );
    }
    use git_setup::{Host, token_help};
    let host = |text: &str| Host::of(&Location::parse(text, false).unwrap());
    assert_eq!(host("https://github.com/me/lib"), Host::GitHub);
    assert_eq!(host("git@github.com:me/lib.git"), Host::GitHub);
    assert_eq!(host("https://GitLab.com/group/sub/lib.git"), Host::GitLab);
    assert_eq!(host("https://gitea.example/me/lib"), Host::Other);
    let (text, link) = token_help("https://github.com/me/lib");
    assert!(
        text.starts_with(
            "Create a fine-grained token: Repository access “Only select repositories”"
        )
    );
    assert_eq!(
        link.as_deref(),
        Some("https://github.com/settings/personal-access-tokens/new")
    );
    let (text, link) = token_help("https://gitlab.com/group/sub/lib.git");
    assert!(text.contains("read_repository and write_repository"));
    assert_eq!(
        link.as_deref(),
        Some("https://gitlab.com/group/sub/lib/-/settings/access_tokens")
    );
    let (text, link) = token_help("https://codeberg.org/me/lib");
    assert!(text.contains("write:repository") && link.is_none());
}
#[test]
fn branch_names_follow_the_shared_subset() {
    for good in ["main", "snippets", "sync/linux", "a.b", "v1_2-3"] {
        assert!(valid_branch(good), "{good}");
    }
    for bad in [
        "", "-x", "/x", "x/", "x.", "x.lock", "a..b", "a//b", "HEAD", "a/.b", ".a", "a b", "a:b",
        "a~b", "a^b",
    ] {
        assert!(!valid_branch(bad), "{bad:?}");
    }
}
#[test]
fn identities_are_the_apple_digests() {
    use sha2::{Digest, Sha256};
    let remote = Remote::new(
        Location::parse("git@github.com:me/lib.git", false).unwrap(),
        "main",
    )
    .unwrap();
    let dataset = Uuid::parse_str("8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f").unwrap();
    let account: [u8; 32] =
        Sha256::digest("snippets-git-account-v1\ngithub.com/me/lib\nrefs/heads/main").into();
    assert_eq!(git_layout::account_digest(&remote), account);
    let data: [u8; 32] = Sha256::digest(
        "snippets-git-dataset-v1\ngithub.com/me/lib\nrefs/heads/main\n8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f",
    )
    .into();
    assert_eq!(git_layout::dataset_digest(&remote, dataset), data);
    // The same repository over HTTPS shares every identity.
    let https = Remote::new(
        Location::parse("https://github.com/me/lib", false).unwrap(),
        "main",
    )
    .unwrap();
    assert_eq!(
        git_layout::key_scope(&https, dataset),
        git_layout::key_scope(&remote, dataset)
    );
    let key = git_layout::key_scope(&remote, dataset);
    assert!(key.starts_with("git-library-v1-") && key.len() == "git-library-v1-".len() + 32);
    assert_eq!(
        git_layout::record_version("ab".repeat(20).as_str()).len(),
        54
    );
}

// MARK: - Layout

#[test]
fn manifest_bytes_and_strict_decoding() {
    let dataset = Uuid::parse_str("8F0C2B4E-8F6E-4C1A-9D3B-1A2B3C4D5E6F").unwrap();
    let bytes = git_layout::encode_manifest(dataset, Mode::Encrypted);
    assert_eq!(
        std::str::from_utf8(&bytes).unwrap(),
        "{\n  \"datasetID\" : \"8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f\",\n  \"format\" : \"snippets-git-sync\",\n  \"recordProfile\" : \"snippets-wire-v1\",\n  \"schemaVersion\" : 1\n}\n"
    );
    assert_eq!(
        git_layout::decode_manifest(&bytes),
        Ok((dataset, Mode::Encrypted))
    );
    // Compact or reordered JSON is the same manifest.
    let compact = br#"{"schemaVersion":1,"recordProfile":"snippets-wire-v1","format":"snippets-git-sync","datasetID":"8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f"}"#;
    assert_eq!(
        git_layout::decode_manifest(compact),
        Ok((dataset, Mode::Encrypted))
    );
    use git_layout::LayoutError::*;
    for (bytes, expected) in [
        (&b"not json"[..], NotALibrary),
        (br#"{"format":"other"}"#, NotALibrary),
        (br#"[1]"#, NotALibrary),
        (br#"{"format":"snippets-git-sync"}"#, IncompatibleSchema),
        (
            br#"{"datasetID":"8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f","format":"snippets-git-sync","recordProfile":"snippets-wire-v1","schemaVersion":2}"#,
            IncompatibleSchema,
        ),
        (
            br#"{"datasetID":"8F0C2B4E-8F6E-4C1A-9D3B-1A2B3C4D5E6F","format":"snippets-git-sync","recordProfile":"snippets-wire-v1","schemaVersion":1}"#,
            IncompatibleSchema,
        ),
        (
            br#"{"datasetID":"8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f","format":"snippets-git-sync","recordProfile":"snippets-wire-v2","schemaVersion":1}"#,
            IncompatibleSchema,
        ),
        (
            br#"{"datasetID":"8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f","extra":1,"format":"snippets-git-sync","recordProfile":"snippets-wire-v1","schemaVersion":1}"#,
            IncompatibleSchema,
        ),
    ] {
        assert_eq!(git_layout::decode_manifest(bytes), Err(expected));
    }
    assert_eq!(
        git_layout::decode_manifest(&vec![b' '; git_layout::MAX_MANIFEST_BYTES + 1]),
        Err(NotALibrary)
    );
}
#[test]
fn record_files_are_canonical_and_strict() {
    let id = Uuid::parse_str("617A0001-0000-4000-8000-000000000001").unwrap();
    let record = WireRecord {
        id,
        rev: "rev/1".into(),
        deleted: false,
        blob: b"\x00\xffcipher/text".to_vec(),
    };
    let bytes = git_layout::encode_record(&record);
    assert_eq!(
        std::str::from_utf8(&bytes).unwrap(),
        "{\"blob\":\"AP9jaXBoZXIvdGV4dA==\",\"deleted\":false,\"id\":\"617a0001-0000-4000-8000-000000000001\",\"rev\":\"rev/1\"}\n"
    );
    let decoded = git_layout::decode_record(&bytes, id).unwrap();
    assert!(decoded.blob == record.blob && decoded.rev == record.rev && !decoded.deleted);
    let (prefix, name) = git_layout::record_path(id);
    assert_eq!(
        (prefix.as_str(), name.as_str()),
        ("61", "617a0001-0000-4000-8000-000000000001.json")
    );
    assert_eq!(
        git_layout::record_id(name.as_bytes(), prefix.as_bytes()),
        Some(id)
    );
    assert_eq!(
        git_layout::record_id(name.to_uppercase().as_bytes(), b"61"),
        None
    );
    assert_eq!(git_layout::record_id(name.as_bytes(), b"62"), None);
    assert!(git_layout::is_fanout_name(b"0f") && !git_layout::is_fanout_name(b"0F"));
    for bad in [
        r#"{"blob":"AA==","deleted":false,"id":"617a0001-0000-4000-8000-000000000002","rev":"r"}"#,
        r#"{"blob":"AA==","deleted":false,"id":"617a0001-0000-4000-8000-000000000001","rev":""}"#,
        r#"{"blob":"AA=","deleted":false,"id":"617a0001-0000-4000-8000-000000000001","rev":"r"}"#,
        r#"{"blob":"AB==","deleted":false,"id":"617a0001-0000-4000-8000-000000000001","rev":"r"}"#,
        r#"{"blob":"","deleted":false,"id":"617a0001-0000-4000-8000-000000000001","rev":"r"}"#,
        r#"{"blob":"AA==","deleted":0,"id":"617a0001-0000-4000-8000-000000000001","rev":"r"}"#,
        r#"{"blob":"AA==","deleted":false,"id":"617a0001-0000-4000-8000-000000000001","rev":"r","x":1}"#,
        r#"{"blob":"AA==","id":"617a0001-0000-4000-8000-000000000001","rev":"r"}"#,
    ] {
        assert!(
            git_layout::decode_record(bad.as_bytes(), id).is_err(),
            "{bad}"
        );
    }
    let long = format!(
        r#"{{"blob":"AA==","deleted":false,"id":"617a0001-0000-4000-8000-000000000001","rev":"{}"}}"#,
        "r".repeat(257)
    );
    assert!(git_layout::decode_record(long.as_bytes(), id).is_err());
}
#[test]
fn cursors_round_trip_and_reject_foreign_text() {
    let dataset = Uuid::new_v4();
    let commit = "0123456789abcdef0123456789abcdef01234567".to_owned();
    for position in [
        Position::Complete {
            dataset,
            commit: commit.clone(),
        },
        Position::Partial {
            dataset,
            target: commit.clone(),
            base: None,
            offset: 10,
        },
        Position::Partial {
            dataset,
            target: commit.clone(),
            base: Some("1".repeat(40)),
            offset: 20,
        },
    ] {
        assert_eq!(Position::decode(&position.encode()), Some(position));
    }
    let text = format!("git1.{}.{commit}", dataset.hyphenated());
    assert_eq!(
        Position::decode(&text),
        Some(Position::Complete {
            dataset,
            commit: commit.clone()
        })
    );
    for bad in [
        "".to_owned(),
        format!(
            "git1.{}.{}",
            dataset.hyphenated().to_string().to_uppercase(),
            commit
        ),
        format!("git1.{}.{}", dataset.hyphenated(), &commit[..39]),
        format!("git1.{}.{}", dataset.hyphenated(), commit.to_uppercase()),
        format!("git1p.{}.{commit}.full.0", dataset.hyphenated()),
        format!("git1p.{}.{commit}.nope.10", dataset.hyphenated()),
        format!("git2.{}.{commit}", dataset.hyphenated()),
    ] {
        assert_eq!(Position::decode(&bad), None, "{bad}");
    }
}

// MARK: - Recovery envelopes

#[test]
fn recovery_envelopes_open_only_with_their_code_and_library() {
    let dataset = Uuid::new_v4();
    let bundle = Bundle::generate().unwrap();
    let kit = Kit::generate(dataset).unwrap();
    let file = kit.seal(&bundle).unwrap();
    let text = std::str::from_utf8(&file).unwrap();
    assert!(text.starts_with("{\n  \"algorithm\" : \"snippets-git-recovery-hkdf-sha256-aes256gcm-v1\",\n  \"ciphertext\" : \""));
    assert!(text.ends_with(&format!(
        "\",\n  \"datasetID\" : \"{}\",\n  \"schemaVersion\" : 1\n}}\n",
        dataset.hyphenated()
    )));
    let code = kit.code();
    assert_eq!(code.len(), 33);
    // What a person types: lowercase, spaces, misread letters.
    let typed = code
        .to_lowercase()
        .replace('-', " ")
        .replace('1', "l")
        .replace('0', "o");
    let opened = Kit::from_code(&typed, dataset)
        .unwrap()
        .open(&file)
        .unwrap();
    assert_eq!(opened.for_secure_storage(), bundle.for_secure_storage());
    let other = Kit::generate(dataset).unwrap();
    assert!(matches!(
        other.open(&file),
        Err(git_recovery::Failure::IncorrectCode)
    ));
    // The same code for another library never opens it.
    let foreign = Kit::from_code(&code, Uuid::new_v4()).unwrap();
    assert!(matches!(
        foreign.open(&file),
        Err(git_recovery::Failure::InvalidEnvelope)
    ));
    assert!(matches!(
        Kit::from_code("ABCD", dataset),
        Err(git_recovery::Failure::InvalidCode)
    ));
    let mut typo = code.to_string().into_bytes();
    typo[0] = if typo[0] == b'A' { b'B' } else { b'A' };
    assert!(Kit::from_code(std::str::from_utf8(&typo).unwrap(), dataset).is_err());
    let tampered = text.replacen("\"schemaVersion\" : 1", "\"schemaVersion\" : 2", 1);
    assert!(matches!(
        kit.open(tampered.as_bytes()),
        Err(git_recovery::Failure::InvalidEnvelope)
    ));
}

#[test]
fn stderr_classification_is_closed() {
    use git_repo::Failure::*;
    for (text, expected) in [
        (
            "fatal: Authentication failed for 'https://x/'",
            Authentication,
        ),
        (
            "fatal: could not read Username for 'https://x': terminal prompts disabled",
            Authentication,
        ),
        (
            "git@github.com: Permission denied (publickey).",
            Authentication,
        ),
        (
            "fatal: unable to access 'https://x/': The requested URL returned error: 403",
            Authentication,
        ),
        (
            "remote: Repository not found.\nfatal: repository 'https://x/' not found",
            RepositoryNotFound,
        ),
        (
            "fatal: '/srv/x' does not appear to be a git repository",
            RepositoryNotFound,
        ),
        (
            "Host key verification failed.\nfatal: Could not read from remote repository.",
            HostKeyUnverified,
        ),
        (
            "error: RPC failed; HTTP 413 curl 22 The requested URL returned error: 413",
            PushTooLarge,
        ),
        (
            "fatal: unable to access 'https://x/': The requested URL returned error: 429",
            RateLimited,
        ),
        (
            "ssh: Could not resolve hostname x: Name or service not known",
            Unreachable,
        ),
        ("fatal: transport 'file' not allowed", Unsupported),
        ("anything else", Unreachable),
        // Login-script noise over SSH is never an auth or not-found failure.
        (
            "bash: fortune: command not found\nbash: /home/x/.profile: Permission denied\nfatal: Could not read from remote repository.",
            Unreachable,
        ),
        (
            "ERROR: Permission to me/lib.git denied to bob.",
            Authentication,
        ),
        (
            "Unable to negotiate with 192.0.2.1 port 22: no matching key exchange method found.",
            Unsupported,
        ),
        // Read-only deploy keys and tokens (as Apple GitSSHClient).
        (
            "ERROR: The key you are authenticating with has been marked as read only.",
            Authentication,
        ),
        (
            "remote: Write access to repository not granted.",
            Authentication,
        ),
        (
            "ERROR: Permission to me/lib.git denied to deploy key",
            Authentication,
        ),
        // GitLab's protected branches.
        (
            "remote: GitLab: You are not allowed to push code to protected branches on this project.\n ! [remote rejected] main -> main (pre-receive hook declined)",
            PushRefused,
        ),
    ] {
        assert_eq!(git_repo::classify_for_tests(text), expected, "{text}");
    }
}

// MARK: - Devices against a disposable repository

pub(crate) fn plain_git(args: &[&str]) -> std::process::Output {
    Command::new("git")
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_AUTHOR_NAME", "Fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
        .env("GIT_COMMITTER_NAME", "Fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
        .output()
        .unwrap()
}
pub(crate) fn plain_git_ok(args: &[&str]) -> String {
    let output = plain_git(args);
    assert!(output.status.success(), "git {args:?} failed");
    String::from_utf8(output.stdout).unwrap()
}
pub(crate) struct Fixture {
    pub(crate) directory: tempfile::TempDir,
    pub(crate) bare: PathBuf,
    ssh: PathBuf,
}
impl Fixture {
    pub(crate) fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let bare = directory.path().join("remote.git");
        plain_git_ok(&[
            "init",
            "--quiet",
            "--bare",
            "--initial-branch=main",
            bare.to_str().unwrap(),
        ]);
        // A stand-in for ssh: runs the remote command git asks for locally.
        // No network, no agent and no user keys are involved. It reports a
        // supported version like OpenSSH, to stderr.
        let ssh = directory.path().join("fixture-ssh");
        std::fs::write(
            &ssh,
            "#!/bin/sh\n[ \"$1\" = -V ] && { echo 'OpenSSH_9.9p1, fixture' >&2; exit 0; }\nfor last; do :; done\nexec sh -c \"$last\"\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            directory,
            bare,
            ssh,
        }
    }
    pub(crate) fn location(&self) -> String {
        format!("fixture:{}", self.bare.display())
    }
    pub(crate) fn device(&self) -> Device {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("snippets");
        Library::open(root.clone()).unwrap();
        let store = Store::initialize(&root, Memory::default()).unwrap();
        let mut environment = Environment::new(root);
        environment.git.ssh_program = Some(self.ssh.clone());
        Device {
            _directory: directory,
            environment,
            store,
            location: self.location(),
        }
    }
    fn git(&self, args: &[&str]) -> String {
        let mut all = vec!["--git-dir", self.bare.to_str().unwrap()];
        all.extend_from_slice(args);
        plain_git_ok(&all)
    }
}
pub(crate) struct Device {
    _directory: tempfile::TempDir,
    pub(crate) environment: Environment,
    pub(crate) store: Store<Memory>,
    location: String,
}
impl Device {
    pub(crate) fn form(&self) -> Form {
        Form {
            repository: self.location.clone(),
            branch: "main".into(),
            username: String::new(),
            token: Zeroizing::new(String::new()),
        }
    }
    fn library(&self) -> Library {
        Library::open(self.environment.root.clone()).unwrap()
    }
    pub(crate) fn add(&self, keyword: &str, content: &str) {
        let mut snippet = Snippet::new(format!("{keyword} name"), content);
        snippet.keyword = keyword.into();
        self.library().save(snippet, None).unwrap();
    }
    fn find(&self, keyword: &str) -> Snippet {
        self.library()
            .snippets
            .iter()
            .find(|s| s.keyword == keyword)
            .unwrap()
            .clone()
    }
    pub(crate) fn edit(&self, keyword: &str, content: &str) {
        let before = self.find(keyword);
        let mut after = before.clone();
        after.content = content.into();
        self.library().save(after, Some(&before)).unwrap();
    }
    fn delete(&self, keyword: &str) {
        let snippet = self.find(keyword);
        self.library().delete(&snippet).unwrap();
    }
    pub(crate) fn snippets(&self) -> BTreeMap<String, String> {
        self.library()
            .snippets
            .iter()
            .map(|s| (s.keyword.clone(), s.content.clone()))
            .collect()
    }
    /// Bounded cycles until the library settles or needs a decision.
    pub(crate) fn sync(&mut self) -> SyncState {
        for _ in 0..16 {
            let report = git_setup::synchronize(&self.environment, &mut self.store).unwrap();
            if !matches!(
                report.state,
                SyncState::MoreWork | SyncState::PrimaryChanged
            ) {
                return report.state;
            }
        }
        panic!("sync did not settle");
    }
    pub(crate) fn sync_through_deletions(&mut self, choice: Choice) -> Vec<Kind> {
        let mut kinds = vec![];
        loop {
            match self.sync() {
                SyncState::Current => return kinds,
                SyncState::DeletionReview => {
                    let summary = git_setup::deletion_review(
                        &self.environment,
                        &mut self.store,
                        Some(choice),
                    )
                    .unwrap();
                    kinds.push(summary.kind);
                    assert!(kinds.len() < 8);
                }
                state => panic!("unexpected sync state {state:?}"),
            }
        }
    }
    pub(crate) fn create(&mut self) -> Zeroizing<String> {
        self.create_in(Mode::Encrypted)
    }
    pub(crate) fn create_in(&mut self, mode: Mode) -> Zeroizing<String> {
        let form = self.form();
        assert_eq!(
            git_setup::inspect(&self.environment, &mut self.store, &form)
                .unwrap()
                .state,
            State::Empty
        );
        // Fixture repositories are private; Snippets cannot check them.
        git_setup::create(&self.environment, &mut self.store, &form, mode, true)
            .map_err(|(failure, _)| failure)
            .unwrap()
    }
    fn rename(&self, keyword: &str, name: &str) {
        let before = self.find(keyword);
        let mut after = before.clone();
        after.name = name.into();
        self.library().save(after, Some(&before)).unwrap();
    }
    fn join_plain(&mut self, code: Option<&str>, accept: bool) -> std::result::Result<(), Failure> {
        let form = self.form();
        let State::Library { dataset, mode, .. } =
            git_setup::inspect(&self.environment, &mut self.store, &form)?.state
        else {
            panic!("expected a library");
        };
        assert_eq!(mode, Mode::PlainText);
        git_setup::join(
            &self.environment,
            &mut self.store,
            &form,
            dataset,
            mode,
            code,
            accept,
        )
    }
    pub(crate) fn join(&mut self, code: Option<&str>) -> std::result::Result<(), Failure> {
        let form = self.form();
        let State::Library { dataset, mode, .. } =
            git_setup::inspect(&self.environment, &mut self.store, &form)?.state
        else {
            panic!("expected a library");
        };
        git_setup::join(
            &self.environment,
            &mut self.store,
            &form,
            dataset,
            mode,
            code,
            false,
        )
    }
}

#[test]
fn a_new_library_has_the_shared_layout_and_authorship() {
    let fixture = Fixture::new();
    let mut device = fixture.device();
    device.add("alpha", "fixture-plaintext-alpha-6d1f");
    let code = device.create();
    assert_eq!(code.len(), 33);
    let settings = git_setup::Settings::read(&device.environment.root)
        .unwrap()
        .unwrap();
    assert!(settings.automatic && settings.username.is_none());
    assert_eq!(settings.repository, fixture.location());
    // Layout: the manifest, README and recovery envelope in the first commit.
    let manifest = fixture.git(&["cat-file", "blob", "main:snippets-sync.json"]);
    assert_eq!(
        manifest.as_bytes(),
        git_layout::encode_manifest(settings.dataset, Mode::Encrypted).as_slice()
    );
    assert_eq!(
        fixture.git(&["cat-file", "blob", "main:README.md"]),
        git_layout::README_TEXT
    );
    let envelope = fixture.git(&["cat-file", "blob", "main:keys/recovery.json"]);
    Kit::from_code(&code, settings.dataset)
        .unwrap()
        .open(envelope.as_bytes())
        .unwrap();
    let commit = fixture.git(&["cat-file", "commit", "main"]);
    assert!(commit.contains("\nauthor Snippets Sync <sync@snippets.invalid> "));
    assert!(commit.contains("\ncommitter Snippets Sync <sync@snippets.invalid> "));
    assert!(commit.ends_with(" +0000\n\nCreate Snippets library\n"));
    assert!(!commit.contains("\nparent "));

    assert_eq!(device.sync(), SyncState::Current);
    let log = fixture.git(&["log", "--format=%s", "main"]);
    assert_eq!(log, "Sync 1 record\nCreate Snippets library\n");
    let files = fixture.git(&["ls-tree", "-r", "--name-only", "main"]);
    let records: Vec<_> = files
        .lines()
        .filter(|l| l.starts_with("records/"))
        .collect();
    assert_eq!(records.len(), 1);
    let path = records[0];
    let name = path.rsplit('/').next().unwrap();
    assert!(path[8..10] == name[..2] && name.ends_with(".json"));
    let file = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    let id = Uuid::parse_str(name.trim_end_matches(".json")).unwrap();
    git_layout::decode_record(file.as_bytes(), id).unwrap();
    // Only ciphertext reached the host, in any object of its history.
    let objects = plain_git(&[
        "--git-dir",
        fixture.bare.to_str().unwrap(),
        "cat-file",
        "--batch-all-objects",
        "--batch",
    ])
    .stdout;
    let contains = |needle: &[u8]| objects.windows(needle.len()).any(|w| w == needle);
    assert!(!objects.is_empty());
    assert!(!contains(b"fixture-plaintext-alpha") && !contains(b"alpha name"));
    // A second cycle with nothing new writes nothing.
    assert_eq!(device.sync(), SyncState::Current);
    assert_eq!(fixture.git(&["rev-list", "--count", "main"]), "2\n");
}

#[test]
fn devices_join_with_the_recovery_code_and_converge() {
    let fixture = Fixture::new();
    let mut a = fixture.device();
    a.add("alpha", "alpha one");
    let code = a.create();
    assert_eq!(a.sync(), SyncState::Current);

    let mut b = fixture.device();
    b.add("local", "made on b before joining");
    let form = b.form();
    let inspection = git_setup::inspect(&b.environment, &mut b.store, &form).unwrap();
    let State::Library {
        dataset,
        mode,
        key_available,
        recovery_available,
    } = inspection.state
    else {
        panic!("expected a library");
    };
    assert!(!key_available && recovery_available && !inspection.replaces_sync_state);
    assert_eq!(mode, Mode::Encrypted);
    assert_eq!(b.join(None), Err(Failure::RecoveryCodeRequired));
    assert_eq!(
        b.join(Some("not a code")),
        Err(Failure::InvalidRecoveryCode)
    );
    let wrong = Kit::generate(dataset).unwrap().code();
    assert_eq!(b.join(Some(&wrong)), Err(Failure::IncorrectRecoveryCode));
    assert!(
        git_setup::Settings::read(&b.environment.root)
            .unwrap()
            .is_none()
    );
    b.join(Some(&code)).unwrap();
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(
        b.snippets(),
        BTreeMap::from([
            ("alpha".into(), "alpha one".into()),
            ("local".into(), "made on b before joining".into())
        ])
    );
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets(), b.snippets());

    // Edits flow both ways, one commit per batch.
    b.edit("alpha", "alpha edited on b");
    b.add("beta", "beta from b");
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets()["alpha"], "alpha edited on b");
    assert_eq!(a.snippets()["beta"], "beta from b");

    // Concurrent edits of one snippet: the loser's push re-reads the head and
    // its offer comes back as a conflict; both devices converge.
    a.edit("alpha", "alpha concurrent a");
    b.edit("beta", "beta concurrent b");
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets(), b.snippets());
    assert_eq!(a.snippets()["alpha"], "alpha concurrent a");
    assert_eq!(a.snippets()["beta"], "beta concurrent b");

    // A deletion is a tombstone save, reviewed on both devices.
    a.delete("beta");
    assert_eq!(
        a.sync_through_deletions(Choice::Delete),
        vec![Kind::LocalAbsence]
    );
    assert_eq!(
        b.sync_through_deletions(Choice::Delete),
        vec![Kind::CloudDeletion]
    );
    assert!(!b.snippets().contains_key("beta"));
    assert_eq!(a.snippets(), b.snippets());
    let tombstones = fixture.git(&["ls-tree", "-r", "--name-only", "main", "records"]);
    assert_eq!(
        tombstones.lines().count(),
        3,
        "tombstones remain as records"
    );

    // Disconnect forgets the repository but keeps the key: no code needed.
    git_setup::disconnect(&b.environment, &mut b.store).unwrap();
    assert!(
        git_setup::Settings::read(&b.environment.root)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        git_setup::synchronize(&b.environment, &mut b.store).err(),
        Some(Failure::NotConfigured)
    );
    b.join(None).unwrap();
    assert_eq!(b.sync(), SyncState::Current);

    // A replaced recovery code opens the library; the old one no longer does.
    let replaced = git_setup::replace_recovery_code(&a.environment, &mut a.store).unwrap();
    assert_ne!(replaced.as_str(), code.as_str());
    let mut c = fixture.device();
    assert_eq!(c.join(Some(&code)), Err(Failure::IncorrectRecoveryCode));
    c.join(Some(&replaced)).unwrap();
    assert_eq!(c.sync(), SyncState::Current);
    assert_eq!(c.snippets(), a.snippets());
    let log = fixture.git(&["log", "--format=%s", "main"]);
    assert!(log.contains("Replace recovery envelope\n"));
}

#[test]
fn large_libraries_page_through_bounded_snapshots_and_deltas() {
    let fixture = Fixture::new();
    let mut a = fixture.device();
    for index in 0..23 {
        a.add(&format!("k{index:02}"), &format!("body {index}"));
    }
    let code = a.create();
    assert_eq!(a.sync(), SyncState::Current);
    // Ten offers per engine batch: three commits.
    assert_eq!(fixture.git(&["rev-list", "--count", "main"]), "4\n");
    let mut b = fixture.device();
    b.join(Some(&code)).unwrap();
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(b.snippets().len(), 23);
    for index in 0..14 {
        a.edit(&format!("k{index:02}"), &format!("edited {index}"));
    }
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.snippets(), b.snippets());
}

#[test]
fn foreign_branches_replaced_libraries_and_removed_records_stop_sync() {
    // A branch with other content is never overwritten.
    let fixture = Fixture::new();
    let work = fixture.directory.path().join("work");
    plain_git_ok(&[
        "init",
        "--quiet",
        "--initial-branch=main",
        work.to_str().unwrap(),
    ]);
    std::fs::write(work.join("notes.txt"), "someone else's data").unwrap();
    plain_git_ok(&["-C", work.to_str().unwrap(), "add", "notes.txt"]);
    plain_git_ok(&[
        "-C",
        work.to_str().unwrap(),
        "commit",
        "--quiet",
        "-m",
        "notes",
    ]);
    plain_git_ok(&[
        "-C",
        work.to_str().unwrap(),
        "push",
        "--quiet",
        fixture.bare.to_str().unwrap(),
        "main",
    ]);
    let mut device = fixture.device();
    let form = device.form();
    assert_eq!(
        git_setup::inspect(&device.environment, &mut device.store, &form)
            .unwrap()
            .state,
        State::Foreign
    );
    assert_eq!(
        git_setup::create(
            &device.environment,
            &mut device.store,
            &form,
            Mode::Encrypted,
            false
        )
        .err()
        .map(|(failure, _)| failure),
        Some(Failure::Transport(git_transport::Failure::NotALibrary))
    );
    assert_eq!(fixture.git(&["log", "--format=%s", "main"]), "notes\n");

    // A library replaced underneath a device stops it for reconnection.
    let fixture = Fixture::new();
    let mut a = fixture.device();
    a.add("alpha", "alpha");
    a.create();
    assert_eq!(a.sync(), SyncState::Current);
    fixture.git(&["update-ref", "-d", "refs/heads/main"]);
    let mut other = fixture.device();
    other.create();
    assert_eq!(
        git_setup::synchronize(&a.environment, &mut a.store).err(),
        Some(Failure::Transport(git_transport::Failure::LibraryReplaced))
    );
    // Reconnecting adopts the new library through the reviewed journal switch;
    // the old library's key cannot open it, so a code is required.
    let form = a.form();
    let inspection = git_setup::inspect(&a.environment, &mut a.store, &form).unwrap();
    assert!(inspection.replaces_sync_state);

    // A record file removed by hand is remote data loss, never a deletion.
    let fixture = Fixture::new();
    let mut a = fixture.device();
    a.add("alpha", "alpha");
    a.add("beta", "beta");
    a.create();
    assert_eq!(a.sync(), SyncState::Current);
    let clone = fixture.directory.path().join("clone");
    plain_git_ok(&[
        "clone",
        "--quiet",
        fixture.bare.to_str().unwrap(),
        clone.to_str().unwrap(),
    ]);
    let record = plain_git_ok(&["-C", clone.to_str().unwrap(), "ls-files", "records"]);
    let first = record.lines().next().unwrap();
    plain_git_ok(&["-C", clone.to_str().unwrap(), "rm", "--quiet", first]);
    plain_git_ok(&[
        "-C",
        clone.to_str().unwrap(),
        "commit",
        "--quiet",
        "-m",
        "remove",
    ]);
    plain_git_ok(&[
        "-C",
        clone.to_str().unwrap(),
        "push",
        "--quiet",
        "origin",
        "main",
    ]);
    a.add("gamma", "gamma");
    assert_eq!(
        git_setup::synchronize(&a.environment, &mut a.store).err(),
        Some(Failure::Transport(git_transport::Failure::RecordRemoved))
    );
}

#[test]
fn unrelated_files_survive_sync_commits() {
    let fixture = Fixture::new();
    let mut a = fixture.device();
    a.create();
    let clone = fixture.directory.path().join("clone");
    plain_git_ok(&[
        "clone",
        "--quiet",
        fixture.bare.to_str().unwrap(),
        clone.to_str().unwrap(),
    ]);
    std::fs::create_dir_all(clone.join("docs")).unwrap();
    std::fs::write(clone.join("docs/notes.md"), "kept").unwrap();
    plain_git_ok(&["-C", clone.to_str().unwrap(), "add", "docs/notes.md"]);
    plain_git_ok(&[
        "-C",
        clone.to_str().unwrap(),
        "commit",
        "--quiet",
        "-m",
        "notes",
    ]);
    plain_git_ok(&[
        "-C",
        clone.to_str().unwrap(),
        "push",
        "--quiet",
        "origin",
        "main",
    ]);
    a.add("alpha", "alpha");
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(
        fixture.git(&["cat-file", "blob", "main:docs/notes.md"]),
        "kept"
    );
    assert_eq!(
        fixture.git(&["cat-file", "blob", "main:README.md"]),
        git_layout::README_TEXT
    );
}

#[test]
fn switching_from_another_library_keeps_local_snippets() {
    let first = Fixture::new();
    let mut device = first.device();
    device.add("alpha", "alpha");
    device.create();
    assert_eq!(device.sync(), SyncState::Current);
    // A second repository already holds a library from another device.
    let second = Fixture::new();
    let mut other = second.device();
    other.add("remote", "from the second library");
    let code = other.create();
    assert_eq!(other.sync(), SyncState::Current);
    // Connecting the first device there requires Disconnect, then a reviewed
    // journal switch that keeps its local snippets.
    let mut switched = Device {
        location: second.location(),
        ..device
    };
    let form = switched.form();
    let State::Library { dataset, .. } =
        git_setup::inspect(&switched.environment, &mut switched.store, &form)
            .unwrap()
            .state
    else {
        panic!("expected a library");
    };
    assert_eq!(
        git_setup::join(
            &switched.environment,
            &mut switched.store,
            &form,
            dataset,
            Mode::Encrypted,
            Some(&code),
            false
        ),
        Err(Failure::OtherLibraryActive)
    );
    git_setup::disconnect(&switched.environment, &mut switched.store).unwrap();
    assert!(
        git_setup::inspect(&switched.environment, &mut switched.store, &form)
            .unwrap()
            .replaces_sync_state
    );
    git_setup::join(
        &switched.environment,
        &mut switched.store,
        &form,
        dataset,
        Mode::Encrypted,
        Some(&code),
        false,
    )
    .unwrap();
    assert_eq!(switched.sync(), SyncState::Current);
    assert_eq!(
        switched.snippets(),
        BTreeMap::from([
            ("alpha".into(), "alpha".into()),
            ("remote".into(), "from the second library".into())
        ])
    );
    assert_eq!(other.sync(), SyncState::Current);
    assert_eq!(other.snippets(), switched.snippets());
}

#[test]
fn ssh_commands_never_reach_a_shell_with_user_text() {
    // Locations become one git argument; the ssh command line is fixed text.
    let fixture = Fixture::new();
    let mut device = fixture.device();
    let mut form = device.form();
    form.repository = format!(
        "fixture:{}/x$(touch pwned)",
        fixture.directory.path().display()
    );
    assert_eq!(
        git_setup::inspect(&device.environment, &mut device.store, &form).err(),
        Some(Failure::InvalidLocation)
    );
    assert!(!Path::new("pwned").exists());
}

// MARK: - Live fixtures (tests/git-sync-live.sh)

/// HTTPS-style token auth through the real `git http-backend` on loopback.
/// SNIPPETS_GIT_LIVE_HTTP_URL/_USERNAME/_TOKEN_FILE come from the harness.
#[test]
#[ignore = "explicit loopback git http-backend fixture; invoke only via tests/git-sync-live.sh"]
fn live_http_token_transport() {
    let url = std::env::var("SNIPPETS_GIT_LIVE_HTTP_URL").unwrap();
    let username = std::env::var("SNIPPETS_GIT_LIVE_HTTP_USERNAME").unwrap();
    let token =
        std::fs::read_to_string(std::env::var("SNIPPETS_GIT_LIVE_HTTP_TOKEN_FILE").unwrap())
            .unwrap();
    let fixture = Fixture::new();
    let device = |fixture: &Fixture| {
        let mut device = fixture.device();
        device.environment.insecure_loopback = true;
        device.environment.git.allow_insecure_loopback = true;
        device.location = url.clone();
        device
    };
    let form = |token: &str| Form {
        repository: url.clone(),
        branch: "main".into(),
        username: username.clone(),
        token: Zeroizing::new(token.into()),
    };
    let mut a = device(&fixture);
    a.add("alpha", "alpha over http");
    assert_eq!(
        git_setup::inspect(&a.environment, &mut a.store, &form("")).err(),
        Some(Failure::MissingToken)
    );
    assert_eq!(
        git_setup::inspect(&a.environment, &mut a.store, &form("wrong-token")).err(),
        Some(Failure::Transport(git_transport::Failure::Git(
            git_repo::Failure::Authentication
        )))
    );
    assert_eq!(
        git_setup::inspect(&a.environment, &mut a.store, &form(token.trim()))
            .unwrap()
            .state,
        State::Empty
    );
    let code = git_setup::create(
        &a.environment,
        &mut a.store,
        &form(token.trim()),
        Mode::Encrypted,
        false,
    )
    .map_err(|(f, _)| f)
    .unwrap();
    assert_eq!(a.sync(), SyncState::Current);
    // The saved token is reused for the same location and user only.
    let inspection = git_setup::inspect(&a.environment, &mut a.store, &form("")).unwrap();
    assert!(matches!(
        inspection.state,
        State::Library {
            key_available: true,
            ..
        }
    ));
    let mut b = device(&fixture);
    let State::Library { dataset, .. } =
        git_setup::inspect(&b.environment, &mut b.store, &form(token.trim()))
            .unwrap()
            .state
    else {
        panic!("expected a library");
    };
    git_setup::join(
        &b.environment,
        &mut b.store,
        &form(token.trim()),
        dataset,
        Mode::Encrypted,
        Some(&code),
        false,
    )
    .unwrap();
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(b.snippets()["alpha"], "alpha over http");
    b.add("beta", "beta over http");
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets(), b.snippets());
}

/// The system ssh against a private sshd with a throwaway key in a private
/// agent. SNIPPETS_GIT_LIVE_SSH_LOCATION/_CONFIG come from the harness, which
/// also exports the private SSH_AUTH_SOCK and refuses to run without it.
#[test]
#[ignore = "explicit private sshd/agent fixture; invoke only via tests/git-sync-live.sh"]
fn live_system_ssh_transport() {
    let location = std::env::var("SNIPPETS_GIT_LIVE_SSH_LOCATION").unwrap();
    let config = PathBuf::from(std::env::var("SNIPPETS_GIT_LIVE_SSH_CONFIG").unwrap());
    let unknown =
        PathBuf::from(std::env::var("SNIPPETS_GIT_LIVE_SSH_UNKNOWN_HOST_CONFIG").unwrap());
    assert!(std::env::var("SSH_AUTH_SOCK").unwrap().starts_with("/tmp/"));
    let fixture = Fixture::new();
    let device = |fixture: &Fixture, config: &Path| {
        let mut device = fixture.device();
        device.environment.git.ssh_program = None;
        device.environment.git.ssh_config = Some(config.to_owned());
        device.location = location.clone();
        device
    };
    // An unknown host key is refused, never accepted.
    let mut stranger = device(&fixture, &unknown);
    let form = stranger.form();
    assert_eq!(
        git_setup::inspect(&stranger.environment, &mut stranger.store, &form).err(),
        Some(Failure::Transport(git_transport::Failure::Git(
            git_repo::Failure::HostKeyUnverified
        )))
    );
    let mut a = device(&fixture, &config);
    a.add("alpha", "alpha over ssh");
    let code = a.create();
    assert_eq!(a.sync(), SyncState::Current);
    let mut b = device(&fixture, &config);
    b.join(Some(&code)).unwrap();
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(b.snippets()["alpha"], "alpha over ssh");
    b.edit("alpha", "alpha edited over ssh");
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets(), b.snippets());
    // No token was ever stored for SSH.
    let settings = git_setup::Settings::read(&a.environment.root)
        .unwrap()
        .unwrap();
    assert!(settings.username.is_none());

    // A plain-text library over the same ssh: readable Markdown in the
    // repository, consent to join, and edits both ways.
    let plain = std::env::var("SNIPPETS_GIT_LIVE_SSH_PLAIN_LOCATION").unwrap();
    let repo = std::env::var("SNIPPETS_GIT_LIVE_SSH_PLAIN_REPO").unwrap();
    let plain_device = |fixture: &Fixture| {
        let mut device = device(fixture, &config);
        device.location = plain.clone();
        device
    };
    let mut c = plain_device(&fixture);
    c.add("gamma", "gamma plain over ssh 3e1a");
    let code = c.create_in(Mode::PlainText);
    assert_eq!(c.sync(), SyncState::Current);
    let files = plain_git_ok(&["--git-dir", &repo, "ls-tree", "-r", "--name-only", "main"]);
    let file = files
        .lines()
        .find(|f| f.starts_with("snippets/gamma-name-"))
        .unwrap();
    assert!(
        plain_git_ok(&["--git-dir", &repo, "show", &format!("main:{file}")])
            .ends_with("\n---\ngamma plain over ssh 3e1a\n")
    );
    let mut d = plain_device(&fixture);
    assert_eq!(
        d.join_plain(Some(&code), false),
        Err(Failure::PlainTextConsentRequired)
    );
    d.join_plain(Some(&code), true).unwrap();
    assert_eq!(d.sync(), SyncState::Current);
    assert_eq!(d.snippets(), c.snippets());
    d.edit("gamma", "gamma edited over ssh");
    assert_eq!(d.sync(), SyncState::Current);
    assert_eq!(c.sync(), SyncState::Current);
    assert_eq!(c.snippets()["gamma"], "gamma edited over ssh");
    assert!(
        plain_git_ok(&["--git-dir", &repo, "show", &format!("main:{file}")])
            .ends_with("\n---\ngamma edited over ssh\n")
    );
}

// MARK: - Plain-text libraries

#[path = "git_plain_tests.rs"]
mod plain;

impl Fixture {
    /// Commits a change made with plain git, as another writer would.
    fn commit_by_hand(&self, change: impl FnOnce(&Path)) {
        let work = self
            .directory
            .path()
            .join(format!("hand-{}", Uuid::new_v4()));
        plain_git_ok(&[
            "clone",
            "--quiet",
            self.bare.to_str().unwrap(),
            work.to_str().unwrap(),
        ]);
        change(&work);
        let dir = work.to_str().unwrap();
        plain_git_ok(&["-C", dir, "add", "-A"]);
        plain_git_ok(&["-C", dir, "commit", "--quiet", "-m", "Edited by hand"]);
        plain_git_ok(&["-C", dir, "push", "--quiet", "origin", "main"]);
    }
    fn files(&self) -> Vec<String> {
        self.git(&["ls-tree", "-r", "--name-only", "main"])
            .lines()
            .map(str::to_owned)
            .collect()
    }
    fn markdown(&self) -> Vec<String> {
        self.files()
            .into_iter()
            .filter(|f| f.starts_with("snippets/"))
            .collect()
    }
    fn subjects(&self) -> Vec<String> {
        self.git(&["log", "--format=%s", "main"])
            .lines()
            .map(str::to_owned)
            .collect()
    }
    fn all_objects(&self) -> Vec<u8> {
        plain_git(&[
            "--git-dir",
            self.bare.to_str().unwrap(),
            "cat-file",
            "--batch-all-objects",
            "--batch",
        ])
        .stdout
    }
}
fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}
fn replace_in(path: &Path, from: &str, to: &str) {
    let text = std::fs::read_to_string(path).unwrap();
    assert!(text.contains(from), "{from:?} not in {}", path.display());
    std::fs::write(path, text.replace(from, to)).unwrap();
}

#[test]
fn plain_text_libraries_keep_ordinary_snippets_readable_and_converge() {
    let fixture = Fixture::new();
    let mut a = fixture.device();
    a.add("alpha", "alpha body 5c1e");
    let code = a.create_in(Mode::PlainText);
    let settings = git_setup::Settings::read(&a.environment.root)
        .unwrap()
        .unwrap();
    assert_eq!(settings.mode, Mode::PlainText);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(
        fixture
            .git(&["cat-file", "blob", "main:snippets-sync.json"])
            .as_bytes(),
        git_layout::encode_manifest(settings.dataset, Mode::PlainText).as_slice()
    );
    assert_eq!(
        fixture.git(&["cat-file", "blob", "main:README.md"]),
        git_layout::PLAIN_README_TEXT
    );
    // The snippet is a readable file named after it; nothing under records/.
    let alpha = a.find("alpha");
    let path = format!("snippets/alpha-name-{}.md", &alpha.id.to_string()[..8]);
    assert_eq!(fixture.markdown(), vec![path.clone()]);
    assert!(!fixture.files().iter().any(|f| f.starts_with("records/")));
    let file = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    assert!(file.starts_with("---\nname: \"alpha name\"\nkeyword: \"alpha\"\ntags: []\n"));
    assert!(file.ends_with("\n---\nalpha body 5c1e\n"));
    assert!(!git_plain::read(file.as_bytes(), &path, None).unwrap().1);

    // Joining asks for consent first; the mode comes from the manifest.
    let mut b = fixture.device();
    assert_eq!(
        b.join_plain(Some(&code), false),
        Err(Failure::PlainTextConsentRequired)
    );
    assert!(
        git_setup::Settings::read(&b.environment.root)
            .unwrap()
            .is_none()
    );
    b.join_plain(Some(&code), true).unwrap();
    assert_eq!(
        git_setup::Settings::read(&b.environment.root)
            .unwrap()
            .unwrap()
            .mode,
        Mode::PlainText
    );
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(b.snippets(), a.snippets());
    // Reconnecting to the library this device already syncs asks nothing;
    // the same dataset at another branch or repository identity asks again.
    let form = b.form();
    let dataset = git_setup::Settings::read(&b.environment.root)
        .unwrap()
        .unwrap()
        .dataset;
    assert!(!git_setup::joining_needs_consent(
        &b.environment,
        &form,
        dataset,
        Mode::PlainText
    ));
    for other in [
        Form {
            branch: "other".into(),
            ..b.form()
        },
        Form {
            repository: format!("{}-copy", b.form().repository),
            ..b.form()
        },
    ] {
        assert!(git_setup::joining_needs_consent(
            &b.environment,
            &other,
            dataset,
            Mode::PlainText
        ));
    }
    b.join_plain(None, false).unwrap();

    // An edit keeps the path; a rename moves the file.
    b.edit("alpha", "alpha edited on b");
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(fixture.markdown(), vec![path.clone()]);
    b.rename("alpha", "Renamed Alpha");
    assert_eq!(b.sync(), SyncState::Current);
    let path = format!("snippets/renamed-alpha-{}.md", &alpha.id.to_string()[..8]);
    assert_eq!(fixture.markdown(), vec![path.clone()]);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets()["alpha"], "alpha edited on b");

    // An edit made with plain git reaches both devices as one revision: the
    // derived envelope equals the normalized file's, and one commit rewrites it.
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(&path),
            "alpha edited on b",
            "alpha edited in git",
        )
    });
    let edited = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    let (derived, was_edited) = git_plain::read(edited.as_bytes(), &path, None).unwrap();
    assert!(was_edited && derived.origin == git_plain::FOREIGN_DEVICE);
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.snippets()["alpha"], "alpha edited in git");
    assert_eq!(b.snippets(), a.snippets());
    let normalized = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    let (exact, was_edited) = git_plain::read(normalized.as_bytes(), &path, None).unwrap();
    assert!(!was_edited);
    assert_eq!(exact.hash().unwrap(), derived.hash().unwrap());
    let normalizations = |f: &Fixture| {
        f.subjects()
            .iter()
            .filter(|s| s.starts_with("Normalize"))
            .count()
    };
    assert_eq!(normalizations(&fixture), 1);
    assert_eq!(
        fixture.subjects()[0],
        "Normalize 1 file(s) edited outside Snippets"
    );
    // Nothing is pushed back and forth afterwards.
    let commits = fixture.subjects().len();
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(fixture.subjects().len(), commits);

    // A file added by hand is a new snippet on both devices.
    fixture.commit_by_hand(|work| {
        std::fs::write(
            work.join("snippets/added.md"),
            "---\nname: Added\nkeyword: added\ntags:\n  - one\n  - two\n---\nAdded by hand\n",
        )
        .unwrap()
    });
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(b.sync(), SyncState::Current);
    assert_eq!(a.snippets()["added"], "Added by hand");
    assert_eq!(b.snippets(), a.snippets());
    assert_eq!(normalizations(&fixture), 2);

    // A file deleted by hand is a reviewed deletion on both devices, recorded
    // as a tombstone under records/ in the normalize commit.
    fixture.commit_by_hand(|work| std::fs::remove_file(work.join("snippets/added.md")).unwrap());
    assert_eq!(
        a.sync_through_deletions(Choice::Delete),
        vec![Kind::CloudDeletion]
    );
    assert_eq!(
        b.sync_through_deletions(Choice::Delete),
        vec![Kind::CloudDeletion]
    );
    assert!(!a.snippets().contains_key("added") && a.snippets() == b.snippets());

    // A Markdown file broken by hand does not stop sync: it is skipped with a
    // warning, other changes still arrive, and an edit of it waits.
    let intact = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(&path),
            "\n---\nalpha edited in git",
            "\nalpha edited in git",
        );
        std::fs::write(
            work.join("snippets/other.md"),
            "---\nname: Other\nkeyword: other\n---\nstill syncs\n",
        )
        .unwrap();
    });
    let report = git_setup::synchronize(&b.environment, &mut b.store).unwrap();
    assert_eq!(report.state, SyncState::Current);
    assert_eq!((report.unreadable_files, report.refused_unreadable), (1, 0));
    assert!(
        report
            .warning()
            .unwrap()
            .starts_with("1 snippet file in the repository cannot be read")
    );
    assert_eq!(b.snippets()["other"], "still syncs");
    assert_eq!(b.snippets()["alpha"], "alpha edited in git");
    let broken = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    b.edit("alpha", "alpha edited on b while broken");
    let report = git_setup::synchronize(&b.environment, &mut b.store).unwrap();
    assert!(matches!(
        report.state,
        SyncState::Deferred { retry_after: None }
    ));
    assert_eq!(report.refused_unreadable, 1);
    assert_eq!(
        fixture.git(&["cat-file", "blob", &format!("main:{path}")]),
        broken
    );
    // Fixing the file (here: restoring it) lets the waiting edit through.
    fixture.commit_by_hand(|work| std::fs::write(work.join(&path), &intact).unwrap());
    assert_eq!(b.sync(), SyncState::Current);
    let fixed = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    assert!(fixed.ends_with("\n---\nalpha edited on b while broken\n"));
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets()["alpha"], "alpha edited on b while broken");
    assert_eq!(a.snippets(), b.snippets());
    let id = git_plain::derived_id("snippets/added.md").to_string();
    assert!(
        fixture
            .files()
            .iter()
            .any(|f| f == &format!("records/{}/{id}.json", &id[..2]))
    );
    assert!(normalizations(&fixture) >= 3);
    assert!(fixture.markdown().contains(&path));
}

/// Transport-level: what the Linux engine cannot produce itself (secure
/// records) or would need a second writer for.
fn plain_transport(fixture: &Fixture, name: &str, key: &[u8; 64]) -> git_transport::GitTransport {
    transport_with(fixture, name, Some(key), Some(Mode::PlainText))
}
/// A data-plane transport with the agreed mode `mode`; the key reaches it
/// only for plain text, as in `git_setup`.
fn transport_with(
    fixture: &Fixture,
    name: &str,
    key: Option<&[u8; 64]>,
    mode: Option<Mode>,
) -> git_transport::GitTransport {
    git_transport::GitTransport::new(git_transport::Configuration {
        remote: Remote::new(Location::parse(&fixture.location(), false).unwrap(), "main").unwrap(),
        credential: None,
        cache: fixture.directory.path().join(format!("cache-{name}")),
        expected_dataset: None,
        options: git_repo::Options {
            ssh_program: Some(fixture.ssh.clone()),
            ..Default::default()
        },
        now: git_transport::now,
        plain_key: key
            .filter(|_| mode == Some(Mode::PlainText))
            .map(git_transport::PlainKey::from_material),
        expected_mode: mode,
    })
    .unwrap()
}
struct Wire {
    root: crate::crypto::RootKey,
    salt: [u8; 32],
}
impl Wire {
    fn new(key: &[u8; 64]) -> Self {
        Self {
            root: crate::crypto::RootKey::from_bytes(&key[..32]).unwrap(),
            salt: key[32..].try_into().unwrap(),
        }
    }
    fn offer(&self, envelope: &Envelope, version: Option<cloud::RecordVersion>) -> cloud::Offer {
        cloud::Offer {
            record: WireRecord::seal(envelope, &self.root, &self.salt).unwrap(),
            expected_record_version: version,
        }
    }
    fn open(&self, record: cloud::ServerRecord) -> (Envelope, String) {
        let (wire, version) = record.into_parts();
        (
            wire.open(&self.root, &self.salt).unwrap(),
            version.for_checkpoint().to_owned(),
        )
    }
}
fn envelope(name: &str, content: &str, wall: u64) -> Envelope {
    let mut snippet = Snippet::new(name, content);
    snippet.keyword = name.to_lowercase();
    Envelope::plain(
        &snippet,
        Hlc::parse(&format!("{wall:012x}-0000-a1b2c3d4")).unwrap(),
        "a1b2c3d4".into(),
    )
    .unwrap()
}
fn submit(
    transport: &mut git_transport::GitTransport,
    offers: &[cloud::Offer],
) -> Vec<cloud::Outcome> {
    sender::Remote::submit(transport, offers)
        .ok()
        .unwrap()
        .outcomes
}
fn accepted(outcome: &cloud::Outcome) -> cloud::RecordVersion {
    match outcome {
        cloud::Outcome::Accepted { record_version, .. } => record_version.clone(),
        _ => panic!("not accepted"),
    }
}
fn fetch(
    transport: &mut git_transport::GitTransport,
    cursor: Option<&cloud::Cursor>,
) -> receiver::FetchedPage {
    receiver::Remote::fetch(transport, cursor).ok().unwrap()
}

/// Which snippet a file is depends only on the file (its hash-covered `sync`
/// id), never on a device's history; an edit of a file deleted by hand meets
/// the deletion as a conflict even on a device without the file; and a
/// manifest naming another mode than agreed stops sync.
#[test]
fn plain_text_identity_comes_from_the_files_and_the_mode_is_pinned() {
    let fixture = Fixture::new();
    let key = [0x3c; 64];
    let wire = Wire::new(&key);
    let mut a = plain_transport(&fixture, "a", &key);
    let dataset = Uuid::new_v4();
    a.initialize(dataset, &[], Mode::PlainText).unwrap();
    let original = envelope("Greeting", "hello 7f20", 1_000);
    accepted(&submit(&mut a, &[wire.offer(&original, None)])[0]);
    let path = format!("snippets/greeting-{}.md", &original.id.to_string()[..8]);
    let mut b = plain_transport(&fixture, "b", &key);
    let cursor = fetch(&mut b, None).cursor;
    let ids = |page: &receiver::FetchedPage| -> Vec<Uuid> {
        page.records
            .iter()
            .map(|r| wire.open(r.clone()).0.id)
            .collect()
    };

    // A removed `id` line: the same snippet from history and from nothing,
    // put back once, and no device keeps rewriting the file.
    fixture.commit_by_hand(|work| {
        replace_in(&work.join(&path), &format!("id: {}\n", original.id), "")
    });
    let from_history = fetch(&mut b, Some(&cursor));
    assert_eq!(ids(&from_history), vec![original.id]);
    let from_nothing = fetch(&mut plain_transport(&fixture, "fresh", &key), None);
    assert_eq!(ids(&from_nothing), vec![original.id]);
    let file = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    assert!(file.contains(&format!("\nid: {}\n", original.id)));
    let commits = fixture.git(&["rev-list", "--count", "main"]);
    let mut cursor = from_history.cursor;
    for round in 0..3 {
        cursor = fetch(&mut b, Some(&cursor)).cursor;
        fetch(
            &mut plain_transport(&fixture, &format!("fresh-{round}"), &key),
            None,
        );
    }
    assert_eq!(fixture.git(&["rev-list", "--count", "main"]), commits);

    // An `id` line naming another snippet does not make the file that one.
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(&path),
            &format!("id: {}", original.id),
            "id: 617a0bbb-0000-4000-8000-000000000bbb",
        )
    });
    let page = fetch(&mut b, Some(&cursor));
    assert_eq!(ids(&page), vec![original.id]);

    // The file deleted by hand, then an edit from a device that lost its
    // cache: a conflict with the lowest deletion, so the edit outranks it.
    let blob = fixture.git(&["rev-parse", &format!("main:{path}")]);
    let version =
        cloud::RecordVersion::from_checkpoint(git_layout::markdown_version(blob.trim())).unwrap();
    fixture.commit_by_hand(|work| std::fs::remove_file(work.join(&path)).unwrap());
    let mut restored = plain_transport(&fixture, "restored", &key);
    let edit = Envelope {
        id: original.id,
        ..envelope("Greeting", "late edit", 900_000)
    };
    let outcomes = submit(&mut restored, &[wire.offer(&edit, Some(version))]);
    let cloud::Outcome::Conflict {
        authoritative_record,
    } = &outcomes[0]
    else {
        panic!("expected the deletion as a conflict");
    };
    let (tombstone, _) = wire.open(authoritative_record.clone());
    assert!(tombstone.deleted && tombstone.id == original.id && !tombstone.secure);
    assert_eq!(tombstone.hlc.text(), "000000000000-0000-00000000");
    assert_eq!(tombstone.origin, git_plain::FOREIGN_DEVICE);
    assert!(tombstone.hlc < edit.hlc);
    // The deletion is then recorded, and delivered with its record version.
    let page = fetch(&mut restored, None);
    let recorded = page
        .records
        .iter()
        .map(|r| wire.open(r.clone()))
        .find(|(e, _)| e.id == original.id)
        .expect("the recorded deletion");
    assert!(recorded.0.deleted && recorded.1.starts_with("git-blob-sha1:"));
    assert!(
        fixture
            .files()
            .iter()
            .any(|f| f.ends_with(&format!("{}.json", original.id)))
    );

    // Agreeing to encrypted and finding plain text (or the reverse) stops.
    let mut victim = transport_with(&fixture, "victim", Some(&key), Some(Mode::Encrypted));
    assert!(receiver::Remote::fetch(&mut victim, None).is_err());
    assert_eq!(
        victim.last_failure(),
        Some(git_transport::Failure::ModeChanged)
    );
    assert!(sender::Remote::submit(&mut victim, &[wire.offer(&edit, None)]).is_err());
    assert_eq!(
        victim.last_failure(),
        Some(git_transport::Failure::ModeChanged)
    );
    assert_eq!(
        git_transport::Failure::ModeChanged.code(),
        "git_library_mode_changed"
    );
}

/// Someone with push access turning an encrypted library into plain text
/// cannot make a device publish its snippets: sync stops, and reconnecting
/// asks for consent again.
#[test]
fn a_changed_library_mode_stops_sync_until_the_user_consents() {
    let fixture = Fixture::new();
    let mut a = fixture.device();
    a.add("alpha", "alpha 5c1d");
    a.create();
    assert_eq!(a.sync(), SyncState::Current);
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(git_layout::MANIFEST),
            git_layout::RECORD_PROFILE,
            git_layout::PLAIN_RECORD_PROFILE,
        )
    });
    a.edit("alpha", "alpha edited 9b7e");
    assert_eq!(
        git_setup::synchronize(&a.environment, &mut a.store).err(),
        Some(Failure::Transport(git_transport::Failure::ModeChanged))
    );
    assert!(fixture.markdown().is_empty(), "nothing was published");
    assert!(!contains(&fixture.all_objects(), b"alpha edited 9b7e"));
    let form = a.form();
    let State::Library { dataset, mode, .. } =
        git_setup::inspect(&a.environment, &mut a.store, &form)
            .unwrap()
            .state
    else {
        panic!("expected a library");
    };
    assert_eq!(mode, Mode::PlainText);
    assert!(git_setup::joining_needs_consent(
        &a.environment,
        &form,
        dataset,
        mode
    ));
    assert_eq!(
        git_setup::join(
            &a.environment,
            &mut a.store,
            &form,
            dataset,
            mode,
            None,
            false
        ),
        Err(Failure::PlainTextConsentRequired)
    );
    // Consent given to the mode shown earlier does not carry over.
    assert_eq!(
        git_setup::join(
            &a.environment,
            &mut a.store,
            &form,
            dataset,
            Mode::Encrypted,
            None,
            true
        ),
        Err(Failure::Transport(git_transport::Failure::ModeChanged))
    );
    // Consenting to the new mode resumes sync: the cursor written in the old
    // mode is refetched in full, and the waiting edit is published as the
    // user now agreed.
    git_setup::join(
        &a.environment,
        &mut a.store,
        &form,
        dataset,
        Mode::PlainText,
        None,
        true,
    )
    .unwrap();
    assert_eq!(a.sync(), SyncState::Current);
    assert_eq!(a.snippets()["alpha"], "alpha edited 9b7e");
    let [file] = fixture.markdown().try_into().unwrap();
    assert!(
        fixture
            .git(&["cat-file", "blob", &format!("main:{file}")])
            .contains("alpha edited 9b7e")
    );
    assert_eq!(a.sync(), SyncState::Current);
}

/// A Markdown file restored by hand while a tombstone shadowed it still
/// claims that id: when the snippet comes back, its file is that one,
/// overwritten, never a `-2` copy that would lose the id to the stale file.
/// A file from a newer Snippets is skipped and never rewritten.
#[test]
fn a_returning_snippet_takes_back_its_shadowed_file() {
    let fixture = Fixture::new();
    let key = [0x2d; 64];
    let wire = Wire::new(&key);
    let mut a = plain_transport(&fixture, "a", &key);
    a.initialize(Uuid::new_v4(), &[], Mode::PlainText).unwrap();
    let live = envelope("Shadow", "shadow body 4e11", 1_000);
    let version = accepted(&submit(&mut a, &[wire.offer(&live, None)])[0]);
    let path = format!("snippets/shadow-{}.md", &live.id.to_string()[..8]);
    let original = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    let deletion = git_plain::tombstone(&live).unwrap();
    let version = accepted(&submit(&mut a, &[wire.offer(&deletion, Some(version))])[0]);
    assert!(fixture.markdown().is_empty());
    fixture.commit_by_hand(|work| {
        std::fs::create_dir_all(work.join("snippets")).unwrap();
        std::fs::write(work.join(&path), &original).unwrap();
    });
    let returning = Envelope {
        id: live.id,
        ..envelope("Shadow", "shadow returns 77b0", 900_000)
    };
    let version = accepted(&submit(&mut a, &[wire.offer(&returning, Some(version))])[0]);
    assert!(version.for_checkpoint().starts_with("git-md-blob-sha1:"));
    assert_eq!(fixture.markdown(), vec![path.clone()]);
    assert!(
        fixture
            .git(&["cat-file", "blob", &format!("main:{path}")])
            .contains("shadow returns 77b0")
    );
    assert!(
        !fixture
            .files()
            .iter()
            .any(|f| f.ends_with(&format!("{}.json", live.id)))
    );
    let page = fetch(&mut plain_transport(&fixture, "fresh", &key), None);
    let [record] = page.records.as_slice() else {
        panic!("one snippet");
    };
    assert!(wire.open(record.clone()).0 == returning);

    // A file from a newer Snippets: skipped with the warning, not rewritten.
    let commits = fixture.git(&["rev-list", "--count", "main"]);
    let newer = format!(
        "---\nname: \"Future\"\nid: 617a0fff-0000-4000-8000-000000000fff\nsync: {}\n---\nfrom a newer build\n",
        base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            r#"{"schemaVersion":2}"#
        )
    );
    fixture.commit_by_hand(|work| std::fs::write(work.join("snippets/future.md"), &newer).unwrap());
    let commits_after_hand = fixture.git(&["rev-list", "--count", "main"]);
    assert_ne!(commits, commits_after_hand);
    let mut b = plain_transport(&fixture, "b", &key);
    let page = fetch(&mut b, None);
    assert_eq!(page.records.len(), 1, "only the returning snippet");
    assert_eq!(b.plain_warnings().0, 1);
    assert_eq!(
        fixture.git(&["rev-list", "--count", "main"]),
        commits_after_hand,
        "never normalized"
    );
    assert_eq!(
        fixture
            .git(&["cat-file", "blob", "main:snippets/future.md"])
            .trim_end(),
        newer.trim_end()
    );
}

#[test]
fn plain_text_transport_keeps_secrets_encrypted_and_follows_hand_edits() {
    let fixture = Fixture::new();
    let key = [0x5a; 64];
    let wire = Wire::new(&key);
    let mut a = plain_transport(&fixture, "a", &key);
    let dataset = Uuid::new_v4();
    a.initialize(dataset, &[], Mode::PlainText).unwrap();
    assert_eq!(
        a.inspect().unwrap(),
        git_transport::RepositoryState::Library {
            dataset,
            mode: Mode::PlainText
        }
    );

    // An ordinary snippet is Markdown; a secure one and one carrying
    // extension data stay ciphertext under records/.
    let plain = envelope("Readable", "readable body 51c2", 1_000);
    let mut secure = envelope("Bank PIN 7d1e", "vault-sealed-9e44", 1_000);
    secure.secure = true;
    let mut extended = envelope("Extended", "extended body", 1_000);
    extended
        .extensions
        .insert("future".into(), crate::canonical::Value::text("kept"));
    let outcomes = submit(
        &mut a,
        &[
            wire.offer(&plain, None),
            wire.offer(&secure, None),
            wire.offer(&extended, None),
        ],
    );
    let plain_version = accepted(&outcomes[0]);
    let secure_version = accepted(&outcomes[1]);
    accepted(&outcomes[2]);
    // Versions say what they name: a Markdown file or a ciphertext record.
    assert!(
        plain_version
            .for_checkpoint()
            .starts_with("git-md-blob-sha1:")
    );
    assert!(
        secure_version
            .for_checkpoint()
            .starts_with("git-blob-sha1:")
    );
    let path = format!("snippets/readable-{}.md", &plain.id.to_string()[..8]);
    assert_eq!(fixture.markdown(), vec![path.clone()]);
    let records: Vec<_> = fixture
        .files()
        .into_iter()
        .filter(|f| f.starts_with("records/"))
        .collect();
    assert_eq!(records.len(), 2);
    let objects = fixture.all_objects();
    assert!(contains(&objects, b"readable body 51c2"));
    for secret in [
        &b"Bank PIN 7d1e"[..],
        b"vault-sealed-9e44",
        b"extended body",
    ] {
        assert!(!contains(&objects, secret));
    }
    let mut b = plain_transport(&fixture, "b", &key);
    let page = fetch(&mut b, None);
    assert!(page.full_snapshot && !page.has_more);
    let mut seen: BTreeMap<Uuid, Envelope> = page
        .records
        .into_iter()
        .map(|r| {
            let (e, _) = wire.open(r);
            (e.id, e)
        })
        .collect();
    assert!(seen.remove(&plain.id) == Some(plain.clone()));
    assert!(seen.remove(&secure.id) == Some(secure.clone()));
    assert!(seen.remove(&extended.id) == Some(extended.clone()));
    let cursor = page.cursor;

    // A copy of a file becomes its own snippet; normalizing writes its id.
    fixture.commit_by_hand(|work| {
        std::fs::copy(work.join(&path), work.join("snippets/copy.md")).unwrap();
    });
    let page = fetch(&mut b, Some(&cursor));
    let copy = git_plain::derived_id("snippets/copy.md");
    let [record] = page.records.as_slice() else {
        panic!("one new snippet");
    };
    let (copied, version) = wire.open(record.clone());
    assert_eq!(copied.id, copy);
    assert_eq!(
        copied.fields.as_ref().unwrap().content.as_slice(),
        b"readable body 51c2"
    );
    assert_eq!(
        fixture.subjects()[0],
        "Normalize 1 file(s) edited outside Snippets"
    );
    let file = fixture.git(&["cat-file", "blob", "main:snippets/copy.md"]);
    assert!(file.contains(&format!("\nid: {copy}\n")));
    // The version delivered is the rewritten file's, tagged as Markdown.
    let blob = fixture.git(&["rev-parse", "main:snippets/copy.md"]);
    assert_eq!(version, git_layout::markdown_version(blob.trim()));
    let cursor = page.cursor;

    // Only the `id` line replaced by another valid id: still that snippet,
    // and the line is put back (Apple `aReplacedIDLineAloneIsRestored`).
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(&path),
            &format!("id: {}", plain.id),
            "id: 617a0bbb-0000-4000-8000-000000000bbb",
        )
    });
    let page = fetch(&mut b, Some(&cursor));
    let [record] = page.records.as_slice() else {
        panic!("the same snippet");
    };
    let (same, _) = wire.open(record.clone());
    assert_eq!(same.id, plain.id);
    assert!(same.origin == git_plain::FOREIGN_DEVICE && same.hlc > plain.hlc);
    let restored = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    assert!(restored.contains(&format!("\nid: {}\n", plain.id)));
    let cursor = page.cursor;

    // A mistyped `id` line keeps the snippet the file was; normalizing the
    // edit restores the line (Apple `aMistypedIDLineKeepsTheSnippet`).
    fixture.commit_by_hand(|work| {
        replace_in(&work.join(&path), &format!("id: {}", plain.id), "id: oops");
        replace_in(
            &work.join(&path),
            "readable body 51c2",
            "edited with a typo",
        );
    });
    let page = fetch(&mut b, Some(&cursor));
    let [record] = page.records.as_slice() else {
        panic!("one changed snippet");
    };
    let (original, typo_version) = wire.open(record.clone());
    assert_eq!(original.id, plain.id);
    assert!(original.origin == git_plain::FOREIGN_DEVICE && original.hlc > plain.hlc);
    assert_eq!(
        original.fields.as_ref().unwrap().content.as_slice(),
        b"edited with a typo"
    );
    let restored = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    assert!(restored.contains(&format!("\nid: {}\n", plain.id)));
    assert_eq!(
        fixture.subjects()[0],
        "Normalize 1 file(s) edited outside Snippets"
    );
    let cursor = page.cursor;

    // A mistake in front matter skips that one file: not delivered, not a
    // deletion, counted as a warning, and an in-app edit of the snippet waits
    // instead of overwriting the file. Fixing the file delivers it.
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(&path),
            "\n---\nedited with a typo",
            "\nedited with a typo",
        )
    });
    let page = fetch(&mut b, Some(&cursor));
    assert!(page.records.is_empty());
    assert_eq!(b.plain_warnings(), (1, 0));
    let broken = fixture.git(&["cat-file", "blob", &format!("main:{path}")]);
    let edit = Envelope {
        id: plain.id,
        ..envelope("Readable", "edited in the app meanwhile", 9_000)
    };
    let version = cloud::RecordVersion::from_checkpoint(typo_version).unwrap();
    let outcomes = submit(&mut b, &[wire.offer(&edit, Some(version))]);
    assert!(matches!(
        outcomes[0],
        cloud::Outcome::Rejected {
            retry_after_seconds: None,
            ..
        }
    ));
    assert_eq!(b.plain_warnings(), (1, 1));
    assert_eq!(
        fixture.git(&["cat-file", "blob", &format!("main:{path}")]),
        broken
    );
    let page = fetch(&mut b, Some(&page.cursor));
    assert!(page.records.is_empty() && b.plain_warnings().0 == 1);
    fixture.commit_by_hand(|work| {
        replace_in(
            &work.join(&path),
            "\nedited with a typo",
            "\n---\nfixed by hand",
        )
    });
    let page = fetch(&mut b, Some(&page.cursor));
    let [record] = page.records.as_slice() else {
        panic!("the fixed snippet");
    };
    let (fixed, _) = wire.open(record.clone());
    assert_eq!(fixed.id, plain.id);
    assert_eq!(
        fixed.fields.as_ref().unwrap().content.as_slice(),
        b"fixed by hand"
    );
    assert_eq!(b.plain_warnings().0, 0);
    let cursor = page.cursor;

    // A hand deletion that cannot be recorded yet is retried on later
    // fetches, even when the branch has not moved since.
    let hook = fixture.bare.join("hooks/pre-receive");
    std::fs::write(
        &hook,
        "#!/bin/sh\nwhile read old new ref; do\n  git log -1 --format=%s \"$new\" | grep -q '^Normalize' && exit 1\ndone\nexit 0\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    fixture.commit_by_hand(|work| std::fs::remove_file(work.join("snippets/copy.md")).unwrap());
    let page = fetch(&mut b, Some(&cursor));
    let [deletion] = page.records.as_slice() else {
        panic!("one deletion");
    };
    let (tombstone, version) = wire.open(deletion.clone());
    assert!(tombstone.deleted && tombstone.id == copy);
    assert!(git_layout::is_absent_version(&version));
    assert!(!tombstone.extensions.contains_key("userDeletion.v1"));
    assert!(
        !fixture
            .files()
            .iter()
            .any(|f| f.ends_with(&format!("{copy}.json")))
    );
    std::fs::remove_file(&hook).unwrap();
    let page = fetch(&mut b, Some(&page.cursor));
    assert!(
        fixture
            .files()
            .iter()
            .any(|f| f.ends_with(&format!("{copy}.json")))
    );
    assert_eq!(
        fixture.subjects()[0],
        "Normalize 1 file(s) edited outside Snippets"
    );
    let [recorded] = page.records.as_slice() else {
        panic!("the recorded tombstone");
    };
    let (recorded, version) = wire.open(recorded.clone());
    assert!(recorded == tombstone && version.starts_with("git-blob-sha1:"));

    // An edit for a Markdown file that was deleted by hand is answered with
    // the deletion every device derives, as a conflict.
    let doomed = envelope("Doomed", "doomed body", 2_000);
    let outcomes = submit(&mut a, &[wire.offer(&doomed, None)]);
    let doomed_version = accepted(&outcomes[0]);
    let doomed_path = format!("snippets/doomed-{}.md", &doomed.id.to_string()[..8]);
    fixture.commit_by_hand(|work| std::fs::remove_file(work.join(&doomed_path)).unwrap());
    let edit = envelope("Doomed", "doomed edited", 3_000);
    let edit = Envelope {
        id: doomed.id,
        ..edit
    };
    let outcomes = submit(&mut a, &[wire.offer(&edit, Some(doomed_version))]);
    let cloud::Outcome::Conflict {
        authoritative_record,
    } = &outcomes[0]
    else {
        panic!("expected the derived deletion as a conflict");
    };
    let (remote, _) = wire.open(authoritative_record.clone());
    assert!(remote.deleted && remote.id == doomed.id && remote.hlc > doomed.hlc);
    // A vanished version that names no Markdown file is still a reviewed reset.
    assert!(sender::Remote::submit(&mut a, &[wire.offer(&edit, Some(secure_version))]).is_err());
    assert_eq!(
        a.last_failure(),
        Some(git_transport::Failure::RecordRemoved)
    );
}

use super::*;

#[test]
#[ignore = "requires the explicitly owned headless GNOME lab and its real portal permission dialog"]
fn native_gnome_portal_keyboard_fixture() {
    let lab = std::env::var("SNIPPETS_GNOME_SHORTCUT_LIVE").expect("owned lab path");
    assert!(lab.starts_with("/tmp/snippets-gnome-"));
    assert_eq!(
        std::env::var("XDG_RUNTIME_DIR").unwrap(),
        format!("{lab}/runtime")
    );
    assert_eq!(std::env::var("WAYLAND_DISPLAY").unwrap(), "snippets-lab");
    let output = std::path::Path::new(&lab).join("portal-fixture-status");
    let mut portal = Portal::open(&|| Ok(())).expect("real GNOME shortcut portal registration");
    std::fs::write(&output, "registered\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    let expected = [Action::Open, Action::Picker, Action::Capture];
    let mut count = 0;
    while count < expected.len() {
        assert!(
            Instant::now() < deadline,
            "real portal keyboard fixture timed out"
        );
        if let Some((action, age)) = portal.next(&|| Ok(())).unwrap() {
            assert_eq!(action, expected[count]);
            assert!(age <= Duration::from_millis(1500));
            count += 1;
            std::fs::write(&output, format!("received {count}\n")).unwrap();
        }
    }
    assert_eq!(portal.next(&|| Err(STOPPED)).unwrap_err(), STOPPED);
    assert_eq!(portal.configure(&|| Err(STOPPED)).unwrap_err(), STOPPED);
    let connection = portal.connection.clone();
    drop(portal);
    assert!(connection.is_closed());
    let mut portal = Portal::open(&|| Ok(())).expect("reconnect after releasing the old session");
    std::fs::write(&output, "reconnected\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        assert!(
            Instant::now() < deadline,
            "reconnected keyboard fixture timed out"
        );
        if let Some((action, age)) = portal.next(&|| Ok(())).unwrap() {
            assert_eq!(action, Action::Open);
            assert!(age <= Duration::from_millis(1500));
            break;
        }
    }
    portal
        .call(
            portal.session.as_ref().unwrap().as_str(),
            "org.freedesktop.portal.Session",
            "Close",
            None,
        )
        .unwrap();
    // A client-initiated Close unexports the object; the portal need not send
    // that same client a server-initiated Closed notification.
    assert!(
        portal
            .call(
                portal.session.as_ref().unwrap().as_str(),
                "org.freedesktop.portal.Session",
                "Close",
                None
            )
            .is_err()
    );
    drop(portal);
    if std::env::var_os("SNIPPETS_GNOME_PORTAL_RESTART").is_some() {
        let mut portal = Portal::open(&|| Ok(())).expect("register before portal disappearance");
        std::fs::write(&output, "revoke-owner\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while portal.next(&|| Ok(())).is_ok() {
            assert!(
                Instant::now() < deadline,
                "lost portal owner stayed available"
            );
        }
        drop(portal);
        // A new owner can establish a fresh session after the old one is revoked.
        let mut portal = Portal::open(&|| Ok(())).expect("register with replacement portal owner");
        std::fs::write(&output, "replacement-registered\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            assert!(
                Instant::now() < deadline,
                "replacement portal did not deliver a real shortcut"
            );
            if let Some((action, _)) = portal.next(&|| Ok(())).unwrap() {
                assert_eq!(action, Action::Open);
                break;
            }
        }
        drop(portal);
    }
    std::fs::write(output, "passed\n").unwrap();
}

fn signal(path: &str, id: &str, stamp: u64, options: Options) -> glib::Variant {
    (ObjectPath::try_from(path).unwrap(), id, stamp, options).to_variant()
}
#[test]
fn only_bound_actions_for_this_session_with_fresh_gnome_timestamps_are_admitted() {
    let bound = HashSet::from(["open".into()]);
    let path = "/public/session";
    let parse = |value| activation(&value, path, &bound, 2000);
    assert!(parse(signal(path, "open", 1990, Options::new())).is_some());
    for value in [
        signal("/other/session", "open", 1990, Options::new()),
        signal(path, "picker", 1990, Options::new()),
        signal(path, "unknown", 1990, Options::new()),
        signal(path, "open", 499, Options::new()),
        signal(path, "open", 2001, Options::new()),
        signal(path, "open", u64::MAX, Options::new()),
        (0u32,).to_variant(),
    ] {
        assert!(parse(value).is_none());
    }
    let wrapped = activation(
        &signal(path, "open", u64::from(u32::MAX - 5), Options::new()),
        path,
        &bound,
        10,
    )
    .unwrap();
    assert_eq!(wrapped.1, Duration::from_millis(16));
}
#[test]
fn activation_tokens_are_ephemeral_bounded_and_typed() {
    let path = "/public/session";
    let bound = HashSet::from(["open".into()]);
    for value in [
        "".to_variant(),
        "x\n".to_variant(),
        "x".repeat(4097).to_variant(),
        42u32.to_variant(),
    ] {
        let options = Options::from([("activation_token".into(), value)]);
        assert!(activation(&signal(path, "open", 100, options), path, &bound, 100).is_none());
    }
    let options = Options::from([(
        "activation_token".into(),
        "public-fixture-token".to_variant(),
    )]);
    assert_eq!(
        activation(&signal(path, "open", 100, options), path, &bound, 100)
            .unwrap()
            .2
            .as_deref(),
        Some("public-fixture-token")
    );
}
#[test]
fn binding_responses_reject_duplicates_unknown_actions_and_wrong_types() {
    assert_eq!(
        bindings(&vec![("open", Options::new())].to_variant())
            .unwrap()
            .len(),
        1
    );
    for value in [
        vec![("other", Options::new())].to_variant(),
        vec![("open", Options::new()), ("open", Options::new())].to_variant(),
        "public malformed".to_variant(),
    ] {
        assert!(bindings(&value).is_none());
    }
}

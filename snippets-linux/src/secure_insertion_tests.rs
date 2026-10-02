//! Fictional text, temporary encrypted-source stand-ins and fixture witnesses.
//! Sink reentrancy exercises the production sequence without a real desktop.
use super::*;
fn prepared(body: &str) -> (tempfile::TempDir, Prepared, SessionWitness) {
    let temp = tempfile::tempdir().unwrap();
    fs::create_dir(temp.path().join("Vault")).unwrap();
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        b"Public encrypted source fixture",
    )
    .unwrap();
    let (source, _) = Source::prove(temp.path()).unwrap();
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let authorization = Authorization::new(witness.clone()).unwrap();
    let owner = Prepared::new(
        source,
        Zeroizing::new(body.as_bytes().to_vec()),
        authorization,
    )
    .unwrap();
    (temp, owner, witness)
}
#[derive(Default)]
struct Sink {
    maps: Vec<Vec<u8>>,
    codes: Vec<u32>,
    begins: usize,
    fail: Option<usize>,
    on_key: Option<Box<dyn FnMut(usize)>>,
}
impl Backend for Sink {
    fn begin(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        self.begins += 1;
        Ok(())
    }
    fn install(&mut self, map: &[u8], guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        self.maps.push(map.to_vec());
        Ok(())
    }
    fn key(&mut self, code: u32, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        self.codes.push(code);
        if let Some(callback) = self.on_key.as_mut() {
            callback(self.codes.len());
        }
        if self.fail == Some(self.codes.len()) {
            return Err(CANCELLED);
        }
        guard()
    }
}
#[test]
fn unicode_and_multiline_text_are_paired_without_clipboard_or_automatic_retry() {
    let (_temp, owner, _witness) = prepared("Aя🙂\t\r\nZ\r!");
    let mut sink = Sink::default();
    assert_eq!(
        owner.deliver(&mut sink, "Public clipboard unused").unwrap(),
        8
    );
    assert_eq!(sink.begins, 1);
    assert_eq!(sink.maps.len(), 1);
    assert_eq!(sink.codes, vec![1, 2, 3, 4, 5, 6, 5, 7]);
    let (_temp, owner, _witness) = prepared("Public long output");
    let mut sink = Sink {
        fail: Some(3),
        ..Sink::default()
    };
    assert!(owner.deliver(&mut sink, "").is_err());
    assert_eq!(sink.codes.len(), 3);
    assert_eq!(sink.begins, 1);
}
#[test]
fn changed_focus_lock_epoch_and_source_stop_before_the_next_scalar() {
    for changed in 0..4 {
        let (temp, owner, witness) = prepared("Public text");
        let authorization = owner.authorization.clone();
        let path = temp.path().join("Vault/vault.json");
        let mut sink = Sink {
            on_key: Some(Box::new(move |_| match changed {
                0 => authorization.cancel(),
                1 => witness.test_observe(SessionState::Locked),
                2 => {
                    witness.test_observe(SessionState::Locked);
                    witness.test_observe(SessionState::Unlocked);
                }
                3 => fs::write(&path, b"Public changed encrypted source").unwrap(),
                _ => unreachable!(),
            })),
            ..Sink::default()
        };
        assert!(owner.deliver(&mut sink, "").is_err());
        assert_eq!(sink.codes.len(), 1);
    }
}
#[test]
fn revoked_changed_and_linked_sources_never_open_the_output_backend() {
    for changed in 0..4 {
        let (temp, owner, _witness) = prepared("Public text");
        let path = temp.path().join("Vault/vault.json");
        match changed {
            0 => owner.authorization.cancel(),
            1 => {
                let old = temp.path().join("public-replaced-source");
                fs::rename(&path, &old).unwrap();
                fs::write(&path, b"Public encrypted source fixture").unwrap();
            }
            2 => {
                let other = temp.path().join("public-linked-source");
                fs::rename(&path, &other).unwrap();
                std::os::unix::fs::symlink(&other, &path).unwrap();
            }
            3 => fs::hard_link(&path, temp.path().join("public-second-link")).unwrap(),
            _ => unreachable!(),
        }
        let mut sink = Sink::default();
        assert!(owner.deliver(&mut sink, "").is_err());
        assert_eq!(sink.begins, 0);
        assert!(sink.codes.is_empty());
    }
}
#[test]
fn rendering_is_one_pass_bounded_and_rejects_unsupported_controls_before_any_input() {
    let (_temp, owner, _witness) = prepared("{clipboard}{unknown}");
    assert!(owner.needs_clipboard());
    let mut sink = Sink::default();
    assert_eq!(owner.deliver(&mut sink, "{date}").unwrap(), 15);
    let now = chrono::Local::now();
    assert_eq!(
        &*crate::placeholders::resolve_sensitive_at("{clipboard}", "{date}", now).unwrap(),
        "{date}"
    );
    let oversized = "X".repeat(model::MAX_BODY_BYTES);
    assert!(
        crate::placeholders::resolve_sensitive_at("{clipboard}{clipboard}", &oversized, now)
            .is_err()
    );
    let (_temp, owner, _witness) = prepared("{clipboard}");
    let mut sink = Sink::default();
    assert!(owner.deliver(&mut sink, "\u{1b}").is_err());
    assert_eq!(sink.begins, 0);
}
#[test]
fn multiple_unicode_keymaps_preserve_the_entire_scalar_order() {
    let text = (0..721)
        .map(|n| char::from_u32(0x400 + n).unwrap())
        .collect::<String>();
    let (_temp, owner, _witness) = prepared(&text);
    let mut sink = Sink::default();
    assert_eq!(owner.deliver(&mut sink, "").unwrap(), 721);
    assert_eq!(sink.maps.len(), 4);
    assert_eq!(sink.codes[0], 1);
    assert_eq!(sink.codes[239], 240);
    assert_eq!(sink.codes[240], 1);
    assert_eq!(sink.codes[720], 1);
    #[cfg(feature = "desktop")]
    for map in &sink.maps {
        assert!(super::wayland::valid_keymap(map));
    }
}
#[test]
fn both_clocks_are_fixed_and_cancellation_is_shared_without_extending_authorization() {
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let auth = Authorization::new(witness).unwrap();
    let copy = auth.clone();
    assert!(
        auth.validate_at(auth.started + Duration::from_secs(120), auth.wall)
            .is_err()
    );
    assert!(
        auth.validate_at(auth.started, auth.wall + Duration::from_secs(120))
            .is_err()
    );
    assert!(
        auth.validate_at(auth.started, auth.wall - Duration::from_secs(1))
            .is_err()
    );
    copy.cancel();
    assert!(auth.validate().is_err());
}

use super::*;
use std::os::unix::fs::symlink;

struct Fixture {
    _root: tempfile::TempDir,
    executable: PathBuf,
    config: PathBuf,
    data: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let share = root
            .path()
            .join("Public quote \" percent % dollar $ space/share");
        let executable = share.join("snippets-linux/snippets");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        let engine = executable.with_file_name("snippets-ibus");
        fs::write(&engine, b"public executable fixture").unwrap();
        fs::set_permissions(&engine, fs::Permissions::from_mode(0o755)).unwrap();
        fs::create_dir_all(share.join("ibus/component")).unwrap();
        fs::write(share.join("ibus/component/snippets.xml"), b"<component/>").unwrap();
        Self {
            executable,
            config: root.path().join("config"),
            data: root.path().join("data"),
            _root: root,
        }
    }
    fn plan(&self, paths: &[String]) -> Result<Plan> {
        Plan::prepare(&self.executable, &self.config, &self.data, paths)
    }
    fn unit(&self) -> PathBuf {
        self.config
            .join("systemd/user")
            .join(format!("{UNIT}.d/90-snippets.conf"))
    }
}
#[test]
fn setup_is_explicit_preserves_custom_components_and_is_idempotent() {
    let fixture = Fixture::new();
    let plan = fixture
        .plan(&["/opt/public/components:/opt/public/components".into()])
        .unwrap();
    assert!(!fixture.config.exists() && !fixture.data.exists());
    plan.apply().unwrap();
    let original = fs::read(fixture.unit()).unwrap();
    let paths = previous_paths(&original).unwrap();
    assert_eq!(
        paths
            .iter()
            .filter(|p| *p == "/opt/public/components")
            .count(),
        1
    );
    assert!(
        paths
            .iter()
            .any(|p| p == env!("SNIPPETS_IBUS_COMPONENT_DIR"))
    );
    assert_eq!(
        fs::metadata(fixture.unit()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::read(
            fixture
                .data
                .join("gnome-shell/extensions")
                .join(UUID)
                .join("extension.js")
        )
        .unwrap(),
        include_bytes!("../gnome/snippets@wowlocal.github.io/extension.js")
    );
    fixture.plan(&paths).unwrap().apply().unwrap();
    assert_eq!(fs::read(fixture.unit()).unwrap(), original);
    assert!(!fixture.config.join("dconf").exists());
}
#[test]
fn legacy_setup_upgrades_cache_refresh_without_discarding_custom_paths() {
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.unit().parent().unwrap()).unwrap();
    let paths = vec![
        "/opt/old-snippets/component".into(),
        "/opt/custom/component".into(),
    ];
    let legacy = unit_bytes_version(&paths, false).unwrap();
    fs::write(fixture.unit(), &legacy).unwrap();
    fixture.plan(&paths).unwrap().apply().unwrap();
    let updated = fs::read(fixture.unit()).unwrap();
    assert!(updated.starts_with(HEADER.as_bytes()));
    let text = std::str::from_utf8(&updated).unwrap();
    assert!(text.contains("ExecStartPre=-/usr/bin/ibus write-cache\n"));
    let updated_paths = previous_paths(&updated).unwrap();
    assert!(updated_paths.contains(&paths[1]));
    assert!(!updated_paths.contains(&paths[0]));
    let mut edited = legacy;
    edited.extend_from_slice(b"ExecStartPre=/bin/false\n");
    fs::write(fixture.unit(), &edited).unwrap();
    assert!(fixture.plan(&[]).is_err());
    assert_eq!(fs::read(fixture.unit()).unwrap(), edited);
}

#[test]
fn linked_foreign_and_concurrently_changed_configuration_is_preserved() {
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.unit().parent().unwrap()).unwrap();
    let bytes = b"[Service]\nEnvironment=PUBLIC_OTHER_SETTING=yes\n";
    fs::write(fixture.unit(), bytes).unwrap();
    assert!(fixture.plan(&[]).is_err());
    assert_eq!(fs::read(fixture.unit()).unwrap(), bytes);
    fs::remove_file(fixture.unit()).unwrap();
    let plan = fixture.plan(&[]).unwrap();
    fs::write(fixture.unit(), bytes).unwrap();
    assert_eq!(plan.apply().err(), Some(CHANGED));
    assert!(!fixture.data.exists());
    fs::remove_file(fixture.unit()).unwrap();
    let target = fixture.config.join("public-target");
    fs::write(&target, bytes).unwrap();
    symlink(&target, fixture.unit()).unwrap();
    assert!(fixture.plan(&[]).is_err());
    assert_eq!(fs::read(target).unwrap(), bytes);
}
#[test]
fn foreign_extension_and_invalid_inherited_paths_are_refused_without_writes() {
    let fixture = Fixture::new();
    for paths in [
        vec!["relative".into()],
        vec!["/tmp/a::/tmp/b".into()],
        vec!["/tmp/line\nbreak".into()],
    ] {
        assert!(fixture.plan(&paths).is_err());
    }
    assert!(!fixture.config.exists() && !fixture.data.exists());
    let extension = fixture.data.join("gnome-shell/extensions").join(UUID);
    fs::create_dir_all(&extension).unwrap();
    fs::write(
        extension.join("metadata.json"),
        br#"{"uuid":"other@example.com","version":1}"#,
    )
    .unwrap();
    assert!(fixture.plan(&[]).is_err());
    assert!(!fixture.config.exists());
}

#[test]
fn exact_receipt_detects_added_directives_and_roundtrips_systemd_escaping() {
    let paths = vec![
        "/tmp/Public \" $ % \\ space".into(),
        "/usr/share/ibus/component".into(),
    ];
    let bytes = unit_bytes(&paths).unwrap();
    assert_eq!(previous_paths(&bytes).unwrap(), paths);
    assert!(String::from_utf8_lossy(&bytes).contains("%%"));
    let mut changed = bytes;
    changed.extend_from_slice(b"ExecStart=/bin/false\n");
    assert!(previous_paths(&changed).is_err());
}

#[test]
#[ignore = "requires a native systemd installation; --test parses only and never starts services"]
fn native_systemd_parser_preserves_component_paths() {
    let root = tempfile::tempdir().unwrap();
    let units = root.path().join("units");
    let runtime = root.path().join("runtime");
    fs::create_dir(&units).unwrap();
    fs::DirBuilder::new().mode(0o700).create(&runtime).unwrap();
    let paths = vec![
        "/tmp/Public \" $ % \\ space".into(),
        "/usr/share/ibus/component".into(),
    ];
    let mut unit = b"[Unit]\nDefaultDependencies=no\n[Service]\nExecStart=/usr/bin/true\n".to_vec();
    unit.extend(unit_bytes(&paths).unwrap());
    fs::write(units.join("public-fixture.service"), unit).unwrap();
    let output = std::process::Command::new("/usr/lib/systemd/systemd")
        .args(["--user", "--test", "--unit=public-fixture.service"])
        .env_clear()
        .env("HOME", root.path())
        .env("PATH", "/usr/bin:/bin")
        .env("XDG_RUNTIME_DIR", runtime)
        .env("XDG_CONFIG_HOME", root.path().join("config"))
        .env("SYSTEMD_UNIT_PATH", units)
        .env("LANG", "C")
        .output()
        .expect("native systemd test parser");
    assert!(output.status.success(), "native systemd rejected the unit");
    let stdout = String::from_utf8(output.stdout).unwrap();
    let expected = format!("Environment: IBUS_COMPONENT_PATH={}", paths.join(":"));
    assert!(
        stdout.lines().any(|line| line.trim() == expected),
        "systemd did not preserve the exact component search path"
    );
}

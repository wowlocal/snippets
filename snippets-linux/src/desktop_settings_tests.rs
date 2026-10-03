use super::*;
use std::os::unix::fs::symlink;
#[cfg(feature = "desktop")]
use std::process::Command;
fn executable(root: &Path) -> PathBuf {
    let path = root.join("Public executable");
    fs::write(&path, b"Public fixture").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    path
}
#[test]
fn absent_preferences_and_login_registration_create_nothing_and_default_to_hide() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("Absent root");
    assert!(Preferences::read(&root).unwrap().close_action == CloseAction::Hide);
    let registration = Registration::new(root.clone()).unwrap();
    let snapshot = registration.read().unwrap();
    assert!(!snapshot.enabled && snapshot.executable.is_none());
    assert!(!root.exists());
    assert_eq!(
        config_home(Some("/public/config".as_ref()), Some("/other".as_ref())).unwrap(),
        Path::new("/public/config")
    );
    assert_eq!(
        config_home(Some("".as_ref()), Some("/public/home".as_ref())).unwrap(),
        Path::new("/public/home/.config")
    );
    assert!(config_home(Some("relative".as_ref()), Some("/public/home".as_ref())).is_err());
    assert!(config_home(None, None).is_err());
}
#[test]
fn closed_settings_preserve_future_malformed_oversize_and_linked_inputs() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let path = root.join(SETTINGS);
    Preferences::write(root, CloseAction::Quit).unwrap();
    assert!(Preferences::read(root).unwrap().close_action == CloseAction::Quit);
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    for input in [
        br#"{"schema":2,"close_action":"hide"}"#.to_vec(),
        br#"{"schema":1,"close_action":"other"}"#.to_vec(),
        br#"{"schema":1,"close_action":"hide","extra":true}"#.to_vec(),
        vec![b' '; LIMIT + 1],
    ] {
        fs::write(&path, &input).unwrap();
        assert!(Preferences::read(root).is_err());
        assert!(Preferences::write(root, CloseAction::Hide).is_err());
        assert_eq!(fs::read(&path).unwrap(), input);
    }
    fs::remove_file(&path).unwrap();
    let other = root.join("Other");
    fs::write(&other, b"Public preserved").unwrap();
    symlink(&other, &path).unwrap();
    assert!(Preferences::read(root).is_err());
    assert!(Preferences::write(root, CloseAction::Hide).is_err());
    assert_eq!(fs::read(&other).unwrap(), b"Public preserved");
    fs::remove_file(&path).unwrap();
    fs::hard_link(&other, &path).unwrap();
    assert!(Preferences::read(root).is_err());
}
#[test]
fn explicit_login_changes_are_private_compare_saved_bytes_and_preserve_other_entries() {
    let temp = tempfile::tempdir().unwrap();
    let config = temp.path().join("config");
    let registration = Registration::new(config).unwrap();
    let exe = executable(temp.path());
    let first = registration.read().unwrap();
    let enabled = registration.write(&first, &exe, true).unwrap();
    assert!(enabled.enabled);
    assert_eq!(
        registration.read().unwrap().executable.as_deref(),
        Some(exe.as_path())
    );
    assert_eq!(
        fs::metadata(registration.entry_path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&registration.directory)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    let other = registration.directory.join("Public unrelated.desktop");
    fs::write(&other, b"Public untouched").unwrap();
    let disabled = registration.write(&enabled, &exe, false).unwrap();
    assert!(!disabled.enabled);
    assert!(
        fs::read_to_string(registration.entry_path())
            .unwrap()
            .contains("Hidden=true\n")
    );
    assert!(registration.write(&enabled, &exe, true).is_err());
    assert_eq!(fs::read(&other).unwrap(), b"Public untouched");
    fs::write(
        registration.entry_path(),
        b"[Desktop Entry]\nExec=public-custom-command\n",
    )
    .unwrap();
    assert!(registration.write(&disabled, &exe, true).is_err());
    assert_eq!(
        fs::read(registration.entry_path()).unwrap(),
        b"[Desktop Entry]\nExec=public-custom-command\n"
    );
}
#[test]
fn login_registration_rejects_links_customizations_busy_locks_and_unusable_executables() {
    let temp = tempfile::tempdir().unwrap();
    let registration = Registration::new(temp.path().join("config")).unwrap();
    let exe = executable(temp.path());
    let before = registration.read().unwrap();
    let snapshot = registration.write(&before, &exe, true).unwrap();
    let bytes = fs::read(registration.entry_path()).unwrap();
    for input in [
        bytes
            .iter()
            .copied()
            .chain(b"Extra=value\n".iter().copied())
            .collect(),
        vec![b' '; LIMIT + 1],
    ] {
        fs::write(registration.entry_path(), &input).unwrap();
        assert!(registration.read().is_err());
        assert!(registration.write(&snapshot, &exe, false).is_err());
        assert_eq!(fs::read(registration.entry_path()).unwrap(), input);
    }
    fs::remove_file(registration.entry_path()).unwrap();
    let other = temp.path().join("Public outside");
    fs::write(&other, &bytes).unwrap();
    symlink(&other, registration.entry_path()).unwrap();
    assert!(registration.read().is_err());
    assert!(registration.write(&snapshot, &exe, false).is_err());
    assert_eq!(fs::read(&other).unwrap(), bytes);
    fs::remove_file(registration.entry_path()).unwrap();
    fs::hard_link(&other, registration.entry_path()).unwrap();
    assert!(registration.read().is_err());
    fs::remove_file(registration.entry_path()).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .open(registration.directory.join(".snippets-login.lock"))
        .unwrap();
    lock.lock().unwrap();
    assert!(registration.write(&before, &exe, true).is_err());
    drop(lock);
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(registration.write(&before, &exe, true).is_err());
    for path in [
        Path::new("relative"),
        Path::new("/public/with=equals"),
        Path::new("/public/line\nbreak"),
    ] {
        assert!(entry(path, true).is_err());
    }
    let linked = Registration::new(temp.path().join("linked-config")).unwrap();
    fs::create_dir_all(linked.directory.parent().unwrap()).unwrap();
    symlink(&registration.directory, &linked.directory).unwrap();
    assert!(linked.read().is_err());
}
#[test]
fn login_registration_can_explicitly_follow_an_installation_move_without_losing_old_snapshot() {
    let temp = tempfile::tempdir().unwrap();
    let registration = Registration::new(temp.path().join("config")).unwrap();
    let old = executable(temp.path());
    let before = registration.read().unwrap();
    let enabled = registration.write(&before, &old, true).unwrap();
    let moved = temp.path().join("Moved binary");
    fs::rename(old, &moved).unwrap();
    let read = registration.read().unwrap();
    assert!(read.enabled);
    assert_ne!(read.executable.as_deref(), Some(moved.as_path()));
    let updated = registration.write(&read, &moved, true).unwrap();
    assert!(updated.enabled);
    assert_eq!(updated.executable.as_deref(), Some(moved.as_path()));
    assert!(registration.write(&enabled, &moved, false).is_err());
}
#[test]
fn exec_encoding_and_managed_parser_preserve_spaces_quotes_dollars_backslashes_and_percent() {
    for name in [
        "Public simple",
        "Public space/with 'quote'",
        "Public \"double\" $value `literal`",
        "Public \\path %f %% ; & () #",
        "Public café 中",
    ] {
        let path = Path::new("/tmp").join(name);
        let encoded = argument(&path).unwrap();
        assert_eq!(decoded_argument(&encoded).unwrap(), path);
        let bytes = entry(&path, true).unwrap();
        let text = std::str::from_utf8(&bytes).unwrap();
        assert_eq!(text.matches("Exec=").count(), 1);
        assert!(text.ends_with("X-Snippets-Autostart-Version=1\n"));
    }
    for malformed in ["\"/public/%f\"", "\"/public/$var\"", "\"/public/\\path\""] {
        assert!(decoded_argument(malformed).is_err());
    }
}
#[cfg(feature = "desktop")]
#[test]
fn independent_glib_launcher_and_systemd_generator_accept_the_actual_login_entry() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let flags = Command::new("pkg-config")
        .args(["--cflags", "--libs", "gio-unix-2.0"])
        .output()
        .unwrap();
    assert!(flags.status.success());
    let binary = root.join("Public café \"quote\" $literal `tick` %%f");
    let compiled = Command::new("cc")
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
        .arg(manifest.join("tests/reference/autostart-entry.c"))
        .args(
            std::str::from_utf8(&flags.stdout)
                .unwrap()
                .split_whitespace(),
        )
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let registration = Registration::new(root.join("private config")).unwrap();
    let before = registration.read().unwrap();
    registration.write(&before, &binary, true).unwrap();
    let validated = Command::new("desktop-file-validate")
        .arg(registration.entry_path())
        .output()
        .unwrap();
    assert!(
        validated.status.success(),
        "{}",
        String::from_utf8_lossy(&validated.stderr)
    );
    let proof = root.join("public argv");
    let launched = Command::new(&binary)
        .arg("--launch")
        .arg(registration.entry_path())
        .env("SNIPPETS_STARTUP_PROOF", &proof)
        .env(
            "DBUS_SESSION_BUS_ADDRESS",
            format!("unix:path={}", root.join("absent-bus").display()),
        )
        .output()
        .unwrap();
    assert!(
        launched.status.success(),
        "{}",
        String::from_utf8_lossy(&launched.stderr)
    );
    let argv = fs::read_to_string(proof).unwrap();
    assert_eq!(argv, format!("{}\n--background\n", binary.display()));
    let empty = root.join("empty config dirs");
    fs::create_dir(&empty).unwrap();
    let output = root.join("generated");
    let early = root.join("early");
    let late = root.join("late");
    for dir in [&output, &early, &late] {
        fs::create_dir(dir).unwrap();
    }
    let generated =
        Command::new("/usr/lib/systemd/user-generators/systemd-xdg-autostart-generator")
            .arg(&output)
            .arg(&early)
            .arg(&late)
            .env("XDG_CONFIG_HOME", registration.directory.parent().unwrap())
            .env("XDG_CONFIG_DIRS", &empty)
            .env("XDG_DATA_DIRS", &empty)
            .env("SYSTEMD_LOG_LEVEL", "warning")
            .env("SYSTEMD_SCOPE", "user")
            .output()
            .unwrap();
    assert!(
        generated.status.success(),
        "{}",
        String::from_utf8_lossy(&generated.stderr)
    );
    let services: Vec<_> = [&output, &early, &late]
        .into_iter()
        .flat_map(|dir| fs::read_dir(dir).unwrap())
        .filter_map(|p| {
            let p = p.unwrap().path();
            (p.extension().is_some_and(|e| e == "service")).then_some(p)
        })
        .collect();
    assert_eq!(
        services.len(),
        1,
        "private user generator: {}",
        String::from_utf8_lossy(&generated.stderr)
    );
    let unit = fs::read_to_string(&services[0]).unwrap();
    assert!(unit.contains("ExecStart=") && unit.contains("--background"));
    let filename = services[0].file_name().unwrap();
    assert!([&output, &early, &late].into_iter().any(|dir| {
        dir.join("xdg-desktop-autostart.target.wants")
            .join(filename)
            .exists()
    }));
    // The installed generator cannot preserve a literal backslash; admission
    // must refuse the unusable installation before touching the valid entry.
    let unsupported = root.join("Public \\ binary");
    fs::copy(&binary, &unsupported).unwrap();
    let saved = fs::read(registration.entry_path()).unwrap();
    assert!(
        registration
            .write(&registration.read().unwrap(), &unsupported, true)
            .is_err()
    );
    assert_eq!(fs::read(registration.entry_path()).unwrap(), saved);
    // User Hidden=true must mask an enabled lower-priority system entry.
    let system = root.join("private system");
    fs::create_dir_all(system.join("autostart")).unwrap();
    fs::write(system.join("autostart").join(ENTRY), &saved).unwrap();
    registration
        .write(&registration.read().unwrap(), &binary, false)
        .unwrap();
    let disabled_outputs: Vec<_> = ["disabled-normal", "disabled-early", "disabled-late"]
        .into_iter()
        .map(|name| {
            let path = root.join(name);
            fs::create_dir(&path).unwrap();
            path
        })
        .collect();
    let disabled = Command::new("/usr/lib/systemd/user-generators/systemd-xdg-autostart-generator")
        .args(&disabled_outputs)
        .env("XDG_CONFIG_HOME", registration.directory.parent().unwrap())
        .env("XDG_CONFIG_DIRS", &system)
        .env("XDG_DATA_DIRS", &empty)
        .env("SYSTEMD_LOG_LEVEL", "warning")
        .env("SYSTEMD_SCOPE", "user")
        .output()
        .unwrap();
    assert!(disabled.status.success());
    assert!(disabled_outputs.iter().all(|dir| {
        fs::read_dir(dir)
            .unwrap()
            .all(|p| p.unwrap().path().extension().is_none_or(|e| e != "service"))
    }));
}

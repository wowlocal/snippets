use super::*;
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
};
#[test]
fn absent_shortcut_consent_is_off_and_creates_nothing() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("Public absent library");
    assert!(!Preference::read(&root).unwrap().enabled);
    assert!(!root.exists());
    assert_eq!(Action::from_id(1), Some(Action::Open));
    assert_eq!(Action::from_id(2), Some(Action::Picker));
    assert_eq!(Action::from_id(3), Some(Action::Capture));
    for id in [0, 4, u32::MAX] {
        assert_eq!(Action::from_id(id), None);
    }
}
#[test]
fn explicit_consent_is_private_independent_and_preserves_future_or_unsafe_files() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path();
    Preference::write(root, true).unwrap();
    assert!(Preference::read(root).unwrap().enabled);
    assert_eq!(
        fs::metadata(root.join(FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    Preference::write(root, false).unwrap();
    assert!(!Preference::read(root).unwrap().enabled);
    for data in [
        br#"{"schema":2,"enabled":true}"#.to_vec(),
        br#"{"schema":1,"enabled":true,"body":"Public forbidden"}"#.to_vec(),
        br#"{"schema":1,"enabled":0}"#.to_vec(),
        vec![b' '; 1025],
    ] {
        fs::write(root.join(FILE), &data).unwrap();
        assert!(Preference::read(root).is_err());
        assert!(Preference::write(root, false).is_err());
        assert_eq!(fs::read(root.join(FILE)).unwrap(), data);
    }
    fs::remove_file(root.join(FILE)).unwrap();
    let outside = root.join("Public unrelated");
    fs::write(&outside, b"Public preserved").unwrap();
    symlink(&outside, root.join(FILE)).unwrap();
    assert!(Preference::read(root).is_err());
    fs::remove_file(root.join(FILE)).unwrap();
    fs::hard_link(&outside, root.join(FILE)).unwrap();
    assert!(Preference::read(root).is_err());
    assert!(Preference::write(root, true).is_err());
    assert_eq!(fs::read(outside).unwrap(), b"Public preserved");
    for name in [
        "Vault",
        "Sync",
        "ClipboardHistory",
        "inline-expansion.json",
        "desktop-settings.json",
    ] {
        assert!(!root.join(name).exists());
    }
}

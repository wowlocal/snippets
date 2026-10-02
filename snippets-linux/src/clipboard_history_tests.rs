//! Fictional clipboard text and temporary roots; no native keyring/clipboard.
use super::*;
use crate::secret_store;
use std::{
    cell::Cell,
    collections::BTreeMap,
    os::unix::fs::symlink,
    sync::{Arc, Mutex},
};
const NOW: i64 = 1_000_000_000_000;
const PUBLIC: &str = "Public clipboard fixture {date}\n 🦀 ";
#[derive(Clone, Default)]
struct Memory(Arc<Mutex<State>>);
#[derive(Default)]
struct State {
    values: BTreeMap<([u8; 16], Slot), Zeroizing<Vec<u8>>>,
    writes: usize,
    fault: Option<bool>,
}
impl Backend for Memory {
    fn read(
        &mut self,
        namespace: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        assert!(slot == Slot::ClipboardHistory);
        Ok(self
            .0
            .lock()
            .unwrap()
            .values
            .get(&(*namespace, slot))
            .cloned())
    }
    fn write(
        &mut self,
        namespace: &[u8; 16],
        slot: Slot,
        bytes: &[u8],
    ) -> secret_store::Result<()> {
        assert!(slot == Slot::ClipboardHistory);
        let mut state = self.0.lock().unwrap();
        state.writes += 1;
        let fault = state.fault.take();
        if fault != Some(false) {
            state
                .values
                .insert((*namespace, slot), Zeroizing::new(bytes.into()));
        }
        if fault.is_some() {
            Err(secret_store::Failure::Unavailable)
        } else {
            Ok(())
        }
    }
    fn delete(&mut self, _: &[u8; 16], _: Slot) -> secret_store::Result<()> {
        panic!("history never retires a key implicitly")
    }
}
fn enabled(root: &Path) -> Preference {
    let mut preference = Preference::read(root).unwrap();
    preference
        .save(root, true, preference.excluded_apps.clone())
        .unwrap();
    preference
}
fn add(root: &Path, memory: &Memory, preference: &Preference, text: &str) -> Result<usize> {
    record(
        root,
        memory.clone(),
        preference,
        Zeroizing::new(text.into()),
        NOW,
        &|| Ok(()),
    )
}
fn entry(text: &str, at: i64) -> Entry {
    Entry {
        id: Uuid::new_v4(),
        copied_at_ms: at,
        text: Zeroizing::new(text.into()),
    }
}
fn no_primary(root: &Path) {
    for file in [
        "snippets.json",
        "Vault",
        "Sync",
        "Backups",
        "device.json",
        "automatic-sync.json",
    ] {
        assert!(!root.join(file).exists());
    }
}
#[test]
fn disabled_startup_and_empty_view_clear_never_create_history_or_secret_owner() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = Preference::read(root.path()).unwrap();
    assert!(!preference.enabled);
    assert!(
        load(root.path(), memory.clone(), NOW, &|| Ok(()))
            .unwrap()
            .is_empty()
    );
    clear(root.path(), &|| Ok(())).unwrap();
    assert!(add(root.path(), &memory, &preference, PUBLIC).is_err());
    assert!(!root.path().join("ClipboardHistory").exists());
    assert!(!root.path().join("secret-owner.bin").exists());
    assert!(!root.path().join(PREFERENCE).exists());
    no_primary(root.path());
}
#[test]
fn preferences_are_closed_private_normalized_and_compare_before_replace() {
    let root = tempfile::tempdir().unwrap();
    let mut preference = Preference::read(root.path()).unwrap();
    preference
        .save(
            root.path(),
            true,
            vec![" KeePassXC ".into(), "keepassxc".into()],
        )
        .unwrap();
    assert!(preference.excluded_apps == ["com.khm.snippets.linux", "keepassxc"]);
    let mut stale = Preference::read(root.path()).unwrap();
    preference.save(root.path(), false, vec![]).unwrap();
    assert!(stale.save(root.path(), true, vec![]).is_err());
    let bytes = fs::read(root.path().join(PREFERENCE)).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains(PUBLIC));
    assert_eq!(
        fs::metadata(root.path().join(PREFERENCE))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    value["extra"] = serde_json::json!(true);
    model::atomic_write(
        &root.path().join(PREFERENCE),
        &serde_json::to_vec(&value).unwrap(),
    )
    .unwrap();
    assert!(Preference::read(root.path()).is_err());
    no_primary(root.path());
}
#[test]
fn literal_utf8_normalization_whitespace_and_duplicate_identity_survive_recopies() {
    let entries = recording(Zeroizing::new(PUBLIC.into()), vec![], NOW);
    let id = entries[0].id;
    let entries = recording(Zeroizing::new(PUBLIC.into()), entries, NOW + 5);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, id);
    assert_eq!(entries[0].copied_at_ms, NOW + 5);
    assert_eq!(entries[0].text(), PUBLIC);
    let entries = recording(Zeroizing::new("é".into()), entries, NOW + 6);
    let entries = recording(Zeroizing::new("e\u{301}".into()), entries, NOW + 7);
    assert_eq!(entries.len(), 3);
    assert!(accepts(" \n\t") && !accepts("") && !accepts("x\0y"));
    assert!(!accepts(&"🦀".repeat(MAX_ENTRY_BYTES / 4 + 1)));
}
#[test]
fn retention_expires_exact_boundary_clamps_future_and_deduplicates_without_losing_later_valid_text()
{
    let first = entry("Public A", NOW);
    let mut duplicate_id = entry("Public B", NOW - 1);
    duplicate_id.id = first.id;
    let valid_b = entry("Public B", NOW - 2);
    let future = entry("Public future", NOW + 100);
    let entries = retaining(
        vec![
            first,
            duplicate_id,
            valid_b,
            future,
            entry("Public expired", NOW - RETENTION_MS),
            entry("Public live", NOW - RETENTION_MS + 1),
        ],
        NOW,
    );
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[0].copied_at_ms, NOW);
    assert!(entries.iter().any(|entry| entry.text() == "Public B"));
    assert!(retaining(entries, NOW + RETENTION_MS).is_empty());
}
#[test]
fn entry_and_byte_capacity_keep_the_newest_exact_text_without_partial_entries() {
    let entries = (0..MAX_ENTRIES + 2)
        .map(|i| entry(&format!("Public {i}"), NOW - i as i64))
        .collect();
    let entries = retaining(entries, NOW);
    assert_eq!(entries.len(), MAX_ENTRIES);
    assert_eq!(entries[0].text(), "Public 0");
    let large = (0..129)
        .map(|i| {
            let mut text = format!("{i:04}");
            text.push_str(&"x".repeat(MAX_ENTRY_BYTES - text.len()));
            entry(&text, NOW - i)
        })
        .collect();
    let kept = retaining(large, NOW);
    assert_eq!(kept.len(), 128);
    assert_eq!(
        kept.iter().map(|e| e.text.len()).sum::<usize>(),
        MAX_TOTAL_BYTES
    );
}
#[test]
fn search_combines_diacritic_case_insensitive_terms_and_leaves_placeholders_literal() {
    let entries = vec![
        entry("Public café 🦀 {date}", NOW),
        entry("Other cafe", NOW),
    ];
    assert!(search(" CAFÉ public ", &entries) == vec![entries[0].id]);
    assert!(search("{date}", &entries) == vec![entries[0].id]);
    assert_eq!(search("   ", &entries).len(), 2);
}
#[test]
fn capture_policy_rejects_sensitive_file_internal_and_local_copies_before_text_request() {
    assert!(permits(&["text/plain;charset=utf-8", "text/html"], false));
    assert!(!permits(&["text/plain"], true) && !permits(&["image/png"], false));
    for marker in [
        "x-kde-passwordManagerHint",
        "application/x-keepassxc",
        "text/uri-list",
        "application/x-snippets-clipboard-history",
        "org.nspasteboard.ConcealedType",
    ] {
        assert!(!permits(&["text/plain", marker], false));
    }
    assert!(!source_permitted("", &[]) && !source_permitted("KeePassXC", &["keepassxc".into()]));
    assert!(source_permitted("public-editor", &["keepassxc".into()]));
}
#[test]
fn encrypted_round_trip_local_only_private_files_and_new_nonces() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    let path = root.path().join("ClipboardHistory/history.bin");
    let original = fs::read(&path).unwrap();
    assert!(
        !original
            .windows(PUBLIC.len())
            .any(|bytes| bytes == PUBLIC.as_bytes())
    );
    let entries = load(root.path(), memory.clone(), NOW, &|| Ok(())).unwrap();
    assert_eq!(entries[0].text(), PUBLIC);
    add(root.path(), &memory, &preference, "Public second").unwrap();
    let next = fs::read(&path).unwrap();
    assert_ne!(&original[4..16], &next[4..16]);
    assert_eq!(
        fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.path().join("ClipboardHistory"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(memory.0.lock().unwrap().writes, 1);
    no_primary(root.path());
}
#[test]
fn missing_wrong_and_corrupt_keys_never_get_replacements_or_destroy_history() {
    for fault in 0..3 {
        let root = tempfile::tempdir().unwrap();
        let memory = Memory::default();
        let preference = enabled(root.path());
        add(root.path(), &memory, &preference, PUBLIC).unwrap();
        let before = read_image(root.path()).unwrap().unwrap();
        {
            let mut state = memory.0.lock().unwrap();
            match fault {
                0 => state.values.clear(),
                1 => *state.values.values_mut().next().unwrap() = Zeroizing::new(vec![2; 32]),
                _ => *state.values.values_mut().next().unwrap() = Zeroizing::new(vec![2; 31]),
            }
        }
        assert!(load(root.path(), memory.clone(), NOW, &|| Ok(())).is_err());
        assert!(add(root.path(), &memory, &preference, "Public later").is_err());
        assert_eq!(read_image(root.path()).unwrap().unwrap(), before);
        assert_eq!(memory.0.lock().unwrap().writes, 1);
    }
}
#[test]
fn authentication_rejects_all_ciphertext_layers_and_strict_binary_payloads() {
    let key = [1; 32];
    let entries = vec![entry(PUBLIC, NOW)];
    let image = seal(&entries, &key).unwrap();
    for index in [0, 4, 16, image.len() - 1] {
        let mut broken = image.clone();
        broken[index] ^= 1;
        assert!(open(&broken, &key).is_err());
    }
    assert!(open(&image, &[2; 32]).is_err());
    let encoded = encode(&entries).unwrap();
    for length in [0, 7, encoded.len() - 1] {
        assert!(decode(&encoded[..length]).is_err());
    }
    let mut extra = encoded.to_vec();
    extra.push(1);
    assert!(decode(&extra).is_err());
    let duplicate = vec![entries[0].clone(), entries[0].clone()];
    assert!(decode(&encode(&duplicate).unwrap()).is_err());
}
#[test]
fn interrupted_key_writes_retry_the_retained_key_without_duplicate_initialization() {
    for after in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let memory = Memory::default();
        let preference = enabled(root.path());
        memory.0.lock().unwrap().fault = Some(after);
        assert!(add(root.path(), &memory, &preference, PUBLIC).is_err());
        assert!(read_image(root.path()).unwrap().is_none());
        let retained = memory.0.lock().unwrap().values.values().next().cloned();
        add(root.path(), &memory, &preference, PUBLIC).unwrap();
        let state = memory.0.lock().unwrap();
        assert_eq!(state.writes, if after { 1 } else { 2 });
        if let Some(retained) = retained {
            assert!(*state.values.values().next().unwrap() == retained);
        }
    }
}
#[test]
fn disable_and_stale_preferences_revoke_capture_before_owner_creation() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut preference = enabled(root.path());
    let old = preference.clone();
    preference
        .save(root.path(), false, preference.excluded_apps.clone())
        .unwrap();
    assert!(add(root.path(), &memory, &old, PUBLIC).is_err());
    assert!(!root.path().join("secret-owner.bin").exists());
    assert!(memory.0.lock().unwrap().values.is_empty());
}
#[test]
fn cancelled_reads_and_writes_keep_committed_data_and_never_return_disclosed_text() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    let before = read_image(root.path()).unwrap().unwrap();
    for stop in 1..=6 {
        let count = Cell::new(0);
        let check = || {
            count.set(count.get() + 1);
            if count.get() == stop {
                Err(CANCELLED)
            } else {
                Ok(())
            }
        };
        assert!(
            record(
                root.path(),
                memory.clone(),
                &preference,
                Zeroizing::new("Public cancelled".into()),
                NOW + 1,
                &check
            )
            .is_err()
        );
        assert_eq!(read_image(root.path()).unwrap().unwrap(), before);
    }
    assert!(load(root.path(), memory.clone(), NOW, &|| Err(CANCELLED)).is_err());
}
#[test]
fn pruning_and_individual_deletion_are_durable_and_clear_needs_no_key() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    let entries = load(root.path(), memory.clone(), NOW, &|| Ok(())).unwrap();
    delete(root.path(), memory.clone(), entries[0].id, NOW, &|| Ok(())).unwrap();
    assert!(
        load(root.path(), memory.clone(), NOW, &|| Ok(()))
            .unwrap()
            .is_empty()
    );
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    assert!(
        load(root.path(), memory.clone(), NOW + RETENTION_MS, &|| Ok(()))
            .unwrap()
            .is_empty()
    );
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    memory.0.lock().unwrap().values.clear();
    clear(root.path(), &|| Ok(())).unwrap();
    assert!(!root.path().join("ClipboardHistory/history.bin").exists());
    no_primary(root.path());
}
#[test]
fn linked_hardlinked_and_public_history_inputs_fail_without_overwriting_or_deleting_targets() {
    for fault in 0..4 {
        let root = tempfile::tempdir().unwrap();
        let memory = Memory::default();
        let preference = enabled(root.path());
        add(root.path(), &memory, &preference, PUBLIC).unwrap();
        let path = root.path().join("ClipboardHistory/history.bin");
        let before = fs::read(&path).unwrap();
        match fault {
            0 => {
                let saved = root.path().join("public-target");
                fs::rename(&path, &saved).unwrap();
                symlink(saved, &path).unwrap();
            }
            1 => {
                fs::hard_link(&path, root.path().join("public-link")).unwrap();
            }
            2 => {
                fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            }
            _ => {
                let directory = root.path().join("ClipboardHistory");
                let moved = root.path().join("public-folder");
                fs::rename(&directory, &moved).unwrap();
                symlink(moved, directory).unwrap();
            }
        }
        assert!(load(root.path(), memory.clone(), NOW, &|| Ok(())).is_err());
        assert!(clear(root.path(), &|| Ok(())).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }
}
#[test]
fn independent_history_never_parses_primary_data_or_uses_vault_sync_keys() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    model::atomic_write(
        &root.path().join("snippets.json"),
        b"Public malformed primary fixture",
    )
    .unwrap();
    fs::create_dir(root.path().join("Backups")).unwrap();
    model::atomic_write(
        &root.path().join("Backups/restore.pending"),
        b"Public recovery fence",
    )
    .unwrap();
    assert_eq!(
        load(root.path(), memory.clone(), NOW, &|| Ok(()))
            .unwrap()
            .len(),
        1
    );
    add(root.path(), &memory, &preference, "Public second").unwrap();
    assert_eq!(
        fs::read(root.path().join("snippets.json")).unwrap(),
        b"Public malformed primary fixture"
    );
    assert_eq!(memory.0.lock().unwrap().writes, 1);
}
#[test]
fn explicit_settings_repair_disables_collection_and_preserves_retained_ciphertext() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    let before = read_image(root.path()).unwrap().unwrap();
    model::atomic_write(&root.path().join(PREFERENCE), b"Public damaged preference").unwrap();
    assert!(Preference::read(root.path()).is_err());
    let preference = Preference::reset(root.path()).unwrap();
    assert!(!preference.enabled);
    assert!(Preference::read(root.path()).unwrap() == preference);
    assert_eq!(read_image(root.path()).unwrap().unwrap(), before);
    assert_eq!(memory.0.lock().unwrap().writes, 1);
}
#[test]
fn lost_namespace_and_new_external_images_never_mint_keys_or_overwrite_history() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    let before = read_image(root.path()).unwrap().unwrap();
    let counter = Cell::new(0);
    let check = || {
        counter.set(counter.get() + 1);
        if counter.get() == 6 {
            model::atomic_write(
                &root.path().join("ClipboardHistory/history.bin"),
                b"Public external encrypted image",
            )?;
        }
        Ok(())
    };
    assert!(
        record(
            root.path(),
            memory.clone(),
            &preference,
            Zeroizing::new("Public stale record".into()),
            NOW,
            &check
        )
        .is_err()
    );
    assert_eq!(
        read_image(root.path()).unwrap().unwrap(),
        b"Public external encrypted image"
    );
    model::atomic_write(&root.path().join("ClipboardHistory/history.bin"), &before).unwrap();
    fs::remove_file(root.path().join("secret-owner.bin")).unwrap();
    assert!(load(root.path(), memory.clone(), NOW, &|| Ok(())).is_err());
    assert!(add(root.path(), &memory, &preference, PUBLIC).is_err());
    assert!(!root.path().join("secret-owner.bin").exists());
    assert_eq!(memory.0.lock().unwrap().writes, 1);
    assert_eq!(read_image(root.path()).unwrap().unwrap(), before);
}
#[test]
fn already_published_capture_survives_a_lost_reply_without_duplicate_records() {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let preference = enabled(root.path());
    add(root.path(), &memory, &preference, PUBLIC).unwrap();
    let count = Cell::new(0);
    let check = || {
        count.set(count.get() + 1);
        if count.get() == 7 {
            Err(CANCELLED)
        } else {
            Ok(())
        }
    };
    assert!(
        record(
            root.path(),
            memory.clone(),
            &preference,
            Zeroizing::new("Public later".into()),
            NOW + 1,
            &check
        )
        .is_err()
    );
    let saved = load(root.path(), memory.clone(), NOW + 1, &|| Ok(())).unwrap();
    assert_eq!(saved.len(), 2);
    let id = saved[0].id;
    record(
        root.path(),
        memory.clone(),
        &preference,
        Zeroizing::new("Public later".into()),
        NOW + 2,
        &|| Ok(()),
    )
    .unwrap();
    let saved = load(root.path(), memory.clone(), NOW + 2, &|| Ok(())).unwrap();
    assert_eq!(saved.len(), 2);
    assert_eq!(saved[0].id, id);
}
#[test]
fn explicit_clear_removes_oversized_private_images_and_preserves_replacements() {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("ClipboardHistory")).unwrap();
    fs::set_permissions(
        root.path().join("ClipboardHistory"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    let image = root.path().join("ClipboardHistory/history.bin");
    model::atomic_write(&image, b"Public damaged image").unwrap();
    OpenOptions::new()
        .write(true)
        .open(&image)
        .unwrap()
        .set_len(MAX_CIPHERTEXT as u64 + 1024)
        .unwrap();
    assert!(read_image(root.path()).is_err());
    clear(root.path(), &|| Ok(())).unwrap();
    assert!(!image.exists());
    model::atomic_write(&image, b"Public old image").unwrap();
    let count = Cell::new(0);
    let guard = || {
        count.set(count.get() + 1);
        if count.get() == 2 {
            model::atomic_write(&image, b"Public later image")?;
        }
        Ok(())
    };
    assert!(clear(root.path(), &guard).is_err());
    assert_eq!(fs::read(&image).unwrap(), b"Public later image");
    assert!(!root.path().join("secret-owner.bin").exists());
}

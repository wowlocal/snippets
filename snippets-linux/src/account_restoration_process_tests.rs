//! Kill the exclusive native child while its real WAL/write locks are live.
//! Resume in another process, with only persisted private-fixture authority.
use super::*;
use std::{
    fs,
    os::unix::{fs::PermissionsExt, process::ExitStatusExt},
    path::{Path, PathBuf},
    process::{Child, Command as Process, ExitStatus},
    time::{Duration, Instant},
};

const NAME: &str = "key_store::handover::tests::restoration::foreign::desktop_workflow::process_death::native_restoration_process_kill_and_offline_resume";
const READY: &[u8] = b"ordinary-written-before-vault-or-unwind\n";
const PROTECTED: [Slot; 13] = [
    Slot::Credentials,
    Slot::LibraryKey,
    Slot::CheckpointKey,
    Slot::Bootstrap,
    Slot::PairingRecipient,
    Slot::SpaceCreation,
    Slot::KeyMutation,
    Slot::AccountReview,
    Slot::PairingCandidate,
    Slot::BootstrapCandidate,
    Slot::HistoryMaintenance,
    Slot::AutomaticSync,
    Slot::ClipboardHistory,
];

struct OwnedChild(Option<Child>);
impl OwnedChild {
    fn spawn(stage: &str, control: &Path) -> Self {
        let mut command = Process::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                NAME,
                "--ignored",
                "--test-threads=1",
                "--nocapture",
            ])
            .env("SNIPPETS_RESTORATION_PROCESS_STAGE", stage)
            // SIGKILL cannot run TempDir destructors. Every child-owned PAM
            // scratch file stays under the surviving parent's owned directory.
            .env("TMPDIR", control)
            .env_remove("SNIPPETS_RESTORATION_KILL_CONTROL");
        if stage == "start" {
            command.env("SNIPPETS_RESTORATION_KILL_CONTROL", control);
        }
        Self(Some(command.spawn().unwrap()))
    }
    fn stopped_at_write(&mut self, control: &Path) {
        let started = Instant::now();
        loop {
            let child = self.0.as_mut().unwrap();
            assert!(
                child.try_wait().unwrap().is_none(),
                "Native child ended before its write boundary."
            );
            if fs::read(control.join("ready")).is_ok_and(|bytes| bytes == READY) {
                let status = fs::read_to_string(format!("/proc/{}/status", child.id())).unwrap();
                if status.lines().any(|line| line.starts_with("State:\tT")) {
                    assert_eq!(
                        fs::metadata(control.join("ready"))
                            .unwrap()
                            .permissions()
                            .mode()
                            & 0o777,
                        0o600
                    );
                    return;
                }
            }
            assert!(
                started.elapsed() < Duration::from_secs(90),
                "Native child did not stop at its write boundary."
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn kill_and_reap(&mut self) {
        let child = self.0.as_mut().unwrap();
        child.kill().unwrap();
        let status = child.wait().unwrap();
        self.0.take();
        assert_eq!(status.signal(), Some(libc::SIGKILL));
    }
    fn finish(&mut self) -> ExitStatus {
        let started = Instant::now();
        loop {
            if let Some(status) = self.0.as_mut().unwrap().try_wait().unwrap() {
                self.0.take();
                return status;
            }
            assert!(
                started.elapsed() < Duration::from_secs(90),
                "Fresh native child did not finish."
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn checkpoint(root: &Path) -> (Checkpoint, crate::key_store::history::Catalog) {
    let mut store = Store::load(root, crate::secret_store::Native::new().unwrap()).unwrap();
    let catalog = crate::key_store::history::inspect(&mut store).unwrap();
    let checkpoint = store
        .transaction(|owner| {
            let binding = crate::key_store::installed_binding_locked(owner)
                .unwrap()
                .unwrap();
            let material = owner.checkpoint_material(false)?.unwrap();
            let key = RootKey::from_bytes(&material[..32]).unwrap();
            let salt = material[32..].try_into().unwrap();
            let library = Library::prepare(root.to_owned()).unwrap();
            Ok(Checkpoint::load(&library, &key, &salt, binding.checkpoint_scope()).unwrap())
        })
        .unwrap();
    (checkpoint, catalog)
}
fn protected(root: &Path) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    let mut store = Store::load(root, crate::secret_store::Native::new().unwrap()).unwrap();
    store
        .transaction(|owner| PROTECTED.into_iter().map(|slot| owner.read(slot)).collect())
        .unwrap()
}
fn receipt(root: &Path) -> Option<Zeroizing<Vec<u8>>> {
    let mut store = Store::load(root, crate::secret_store::Native::new().unwrap()).unwrap();
    store
        .transaction(|owner| owner.read(Slot::HistoryRestore))
        .unwrap()
}
fn retained(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let directory = root.join("Sync/Reviews");
    let mut files = BTreeMap::new();
    for entry in fs::read_dir(directory).unwrap() {
        let entry = entry.unwrap();
        assert!(entry.file_type().unwrap().is_file());
        files.insert(
            PathBuf::from(entry.file_name()),
            fs::read(entry.path()).unwrap(),
        );
    }
    assert!(!files.is_empty());
    files
}
fn image(root: &Path, path: &str) -> Option<Zeroizing<Vec<u8>>> {
    crate::model::read_regular(&root.join(path))
        .unwrap()
        .map(Zeroizing::new)
}

#[test]
#[ignore = "explicit native process death and offline continuation; invoke tests/account-live.sh with --restore-process-ordinary"]
fn native_restoration_process_kill_and_offline_resume() {
    let root = PathBuf::from(std::env::var_os("SNIPPETS_SECRET_TEST_ROOT").unwrap());
    assert_eq!(root, crate::model::default_root().unwrap());
    assert_ne!(
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        std::env::var_os("SNIPPETS_SECRET_HOST_BUS")
    );
    assert!(std::env::var_os("SNIPPETS_SUPPORT_DIR").is_none());
    if let Ok(stage) = std::env::var("SNIPPETS_RESTORATION_PROCESS_STAGE") {
        crate::account_ui::live_tests::process_death::child(&root, &stage);
        return;
    }
    // Historical schema 2 intentionally lacks its saved vault header. Its real
    // encrypted image pair and record metadata remain untouched. This extends
    // the existing native process gate, without adding a source/cut matrix.
    let mut saved = saved(false);
    external_source::legacy(&mut saved, 2);
    let source_file = external_source::file(&saved, false);
    let source_file = root.join(source_file.file_name().unwrap());
    let saved = copy_private_native_history(&root, saved);
    let mut native = Store::load(&root, crate::secret_store::Native::new().unwrap()).unwrap();
    let selection = crate::key_store::history::inspect(&mut native)
        .unwrap()
        .switches[0]
        .selection
        .clone();
    assert!(
        crate::key_store::restoration::saved_vault_header(&mut native, &selection)
            .unwrap()
            .is_none()
    );
    drop(native);
    assert!(source_file.is_file());
    let initial = protected(&root);
    let before_plain = image(&root, "snippets.json");
    let before_vault = image(&root, "Vault/vault.json");
    let control = tempfile::Builder::new()
        .prefix("public-restoration-process-")
        .tempdir_in(std::env::var_os("XDG_DATA_HOME").unwrap())
        .unwrap();
    let mut first = OwnedChild::spawn("start", control.path());
    first.stopped_at_write(control.path());
    first.kill_and_reap();
    println!(
        "Owned native process stopped after the durable ordinary write and was reaped with SIGKILL before any failure unwind."
    );

    let (pending, catalog) = checkpoint(&root);
    assert_eq!(catalog.restorations.len(), 1);
    assert_eq!(
        catalog.restorations[0].phase,
        crate::key_store::history::SwitchPhase::Pending
    );
    assert!(catalog.restorations[0].needs_completion);
    let intent = pending.journal.primary_intent.as_ref().unwrap().clone();
    assert!(intent.before_plain == before_plain && intent.before_vault == before_vault);
    assert!(intent.after_plain != intent.before_plain && intent.after_vault != intent.before_vault);
    assert!(image(&root, "snippets.json") == intent.after_plain);
    assert!(image(&root, "Vault/vault.json") == intent.before_vault);
    assert!(root.join("Sync/primary.pending").is_file());
    assert!(Library::prepare(root.clone()).unwrap().read().is_err());
    assert!(protected(&root) == initial && receipt(&root).is_some());
    let history = retained(&root);

    // Completion must use only its durable approved WAL. The previously chosen
    // old header and the killed child's vault/session authority are unavailable.
    fs::remove_file(&source_file).unwrap();

    let mut resume = OwnedChild::spawn("resume", control.path());
    assert!(
        resume.finish().success(),
        "Fresh offline native continuation failed."
    );
    assert!(image(&root, "snippets.json") == intent.after_plain);
    assert!(image(&root, "Vault/vault.json") == intent.after_vault);
    assert!(
        crate::primary::require_ready(&root).is_ok() && !root.join("Sync/primary.pending").exists()
    );
    let (completed, catalog) = checkpoint(&root);
    assert!(completed.journal.primary_intent.is_none());
    assert!(
        pending
            .journal
            .preserves_transport_state(&completed.journal)
    );
    assert!(pending.journal.outbound == completed.journal.outbound);
    assert_eq!(catalog.restorations.len(), 1);
    assert_eq!(
        catalog.restorations[0].phase,
        crate::key_store::history::SwitchPhase::Completed
    );
    assert!(!catalog.restorations[0].needs_completion);
    assert!(protected(&root) == initial && retained(&root) == history);
    let terminal = receipt(&root).unwrap();
    let journal_bytes = fs::read(root.join("Sync/journal.bin")).unwrap();
    let document = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(document.same_identity(&saved.current));
    let library = Library::open(root.clone()).unwrap();
    let mut vault = Vault::open(&library).unwrap();
    vault
        .finish_authentication(
            document.authenticate(CURRENT_PASSPHRASE, false).unwrap(),
            vault.generation(),
        )
        .unwrap();
    for expected in [
        b"Public selected secure C1 body".as_slice(),
        b"Public current independently protected body".as_slice(),
    ] {
        assert!(
            document.records.iter().any(|record| vault
                .body(record.metadata.id)
                .unwrap()
                .as_slice()
                == expected)
        );
    }
    vault.lock();
    drop(vault);

    let mut inspect = OwnedChild::spawn("inspect", control.path());
    assert!(
        inspect.finish().success(),
        "Completed native history did not survive another process restart."
    );
    assert!(
        image(&root, "snippets.json") == intent.after_plain
            && image(&root, "Vault/vault.json") == intent.after_vault
    );
    assert!(fs::read(root.join("Sync/journal.bin")).unwrap() == journal_bytes);
    assert!(
        receipt(&root).unwrap() == terminal
            && protected(&root) == initial
            && retained(&root) == history
    );
    assert!(crate::primary::require_ready(&root).is_ok());
    println!(
        "Three exclusive process lifetimes: authentic missing-header legacy history, actual native old-JSON selection, SIGKILL, fresh PAM-only offline completion without that file, exact WAL after-images, immutable capabilities/ciphertext history, durable terminal receipt and reader fence; no production data or host authentication."
    );
}

//! Native Git Sync window acceptance: a private keyring and bus, an isolated
//! data root, the real worker and system git against a loopback
//! `git http-backend`. Run only through tests/git-sync-desktop-live.sh.
use super::*;
use crate::{model::Library, secret_store::Slot};
use std::path::Path;

fn until(message: &str, mut condition: impl FnMut() -> bool) {
    let context = glib::MainContext::default();
    let deadline = Instant::now() + Duration::from_secs(90);
    while !condition() {
        assert!(Instant::now() < deadline, "{message}");
        while context.pending() {
            context.iteration(false);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn press_response(dialog: &adw::AlertDialog, label: &str) {
    let mut widgets = vec![dialog.clone().upcast::<gtk::Widget>()];
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<gtk::Button>()
            && button.label().as_deref() == Some(label)
        {
            button.emit_clicked();
            return;
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    panic!("response button {label:?} is missing");
}
fn alert(window: &GitWindow, heading: &str) -> adw::AlertDialog {
    let mut found = None;
    until(&format!("dialog {heading:?} did not appear"), || {
        found = window
            .window
            .visible_dialog()
            .and_then(|d| d.downcast::<adw::AlertDialog>().ok())
            .filter(|d| d.heading().as_deref() == Some(heading));
        found.is_some()
    });
    found.unwrap()
}
fn contains(root: &Path, needle: &[u8]) -> bool {
    let mut paths = vec![root.to_path_buf()];
    while let Some(path) = paths.pop() {
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.is_dir() {
            paths.extend(std::fs::read_dir(&path).unwrap().map(|e| e.unwrap().path()));
        } else if metadata.is_file()
            && std::fs::read(&path)
                .unwrap()
                .windows(needle.len())
                .any(|w| w == needle)
        {
            return true;
        }
    }
    false
}
fn secret_present(root: &Path, slot: Slot) -> bool {
    let mut store = Store::load(root, Native::new().unwrap()).unwrap();
    store
        .transaction(|owner| owner.read(slot))
        .unwrap()
        .is_some()
}
fn fill(window: &GitWindow, url: &str, username: &str, token: &str) {
    window.repository.set_text(url);
    window.branch.set_text("main");
    window.username.set_text(username);
    window.token.set_text(token);
    assert!(
        window.username.is_visible() && window.token.is_visible() && !window.ssh_hint.is_visible()
    );
}
fn wait_status(window: &GitWindow, text: &str) {
    until(&format!("status never became {text:?}"), || {
        !window.busy.get() && window.status.label().starts_with(text)
    });
}

#[test]
#[ignore = "explicit native GTK/Secret Service/git fixture; invoke only via tests/git-sync-desktop-live.sh"]
fn live_git_window_creates_joins_reviews_and_disconnects() {
    let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap();
    assert!(
        std::env::var("SNIPPETS_SECRET_TEST_BUS").unwrap() == bus
            && std::env::var("SNIPPETS_SECRET_HOST_BUS").unwrap() != bus
            && std::env::var_os("SNIPPETS_SUPPORT_DIR").is_none()
    );
    let data = PathBuf::from(std::env::var("XDG_DATA_HOME").unwrap());
    assert!(data.starts_with("/tmp"));
    let url = std::env::var("SNIPPETS_GIT_LIVE_HTTP_URL").unwrap();
    let username = std::env::var("SNIPPETS_GIT_LIVE_HTTP_USERNAME").unwrap();
    let token =
        std::fs::read_to_string(std::env::var("SNIPPETS_GIT_LIVE_HTTP_TOKEN_FILE").unwrap())
            .unwrap()
            .trim()
            .to_owned();
    let root_a = data.join("snippets");
    let root_b = data.join("device-b/snippets");
    for root in [&root_a, &root_b] {
        assert!(!root.exists());
    }
    let mut seed = crate::model::Snippet::new("Linux Git", "linux-git-window-initial-3a7e");
    seed.keyword = "linux-git".into();
    Library::open(root_a.clone())
        .unwrap()
        .save(seed, None)
        .unwrap();
    Library::open(root_b.clone()).unwrap();

    adw::init().expect("graphical display");
    let application = adw::Application::builder()
        .application_id("com.khm.snippets.linux.GitSyncAcceptance")
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application
        .register(None::<&gtk::gio::Cancellable>)
        .unwrap();
    let parent = adw::ApplicationWindow::builder()
        .application(&application)
        .title("Public Git Sync Acceptance")
        .build();
    parent.present();

    // Device A creates the library through the window.
    let a = GitWindow::new(
        &application,
        &parent,
        Rc::new(Worker::spawn(root_a.clone())),
    );
    a.window.present();
    a.refresh();
    assert!(!a.connected_group.is_visible());
    assert_eq!(a.window.title().as_deref(), Some("Git Repository"));
    a.repository.set_text("git@github.com:me/lib.git");
    assert!(!a.username.is_visible() && !a.token.is_visible() && a.ssh_hint.is_visible());
    // Token help and user names by host, as on Apple.
    a.repository.set_text("https://github.com/me/lib");
    assert!(a.token_help.is_visible() && a.token_help.label().contains("Contents: Read and write"));
    assert_eq!(a.username.title().as_str(), "User Name (optional)");
    a.repository.set_text("https://gitlab.com/group/lib");
    assert!(
        a.token_help
            .label()
            .contains("gitlab.com/group/lib/-/settings/access_tokens")
    );
    a.repository.set_text(&url);
    assert_eq!(a.username.title().as_str(), "User Name");
    assert!(a.token_help.label().contains("write:repository"));

    // A branch that already has files offers a branch of its own.
    let foreign = std::env::var("SNIPPETS_GIT_LIVE_HTTP_FOREIGN_URL").unwrap();
    fill(&a, &foreign, &username, &token);
    a.check.emit_clicked();
    until("foreign branch was not reported", || {
        !a.busy.get() && a.use_branch.is_visible()
    });
    assert_eq!(a.result.label().as_str(), Failure::ForeignBranch.message());
    a.use_branch.emit_clicked();
    assert_eq!(a.branch.text().as_str(), "snippets");
    until("its own branch was not offered", || {
        !a.busy.get() && a.create.is_visible()
    });
    assert!(!a.use_branch.is_visible());
    fill(&a, &url, &username, "wrong-token");
    a.check.emit_clicked();
    until("wrong token was not refused", || {
        !a.busy.get() && a.result.is_visible()
    });
    assert_eq!(
        a.result.label().as_str(),
        Failure::Transport(crate::git_transport::Failure::Git(
            crate::git_repo::Failure::Authentication
        ))
        .message()
    );
    fill(&a, &url, &username, &token);
    a.check.emit_clicked();
    until("empty branch was not offered", || {
        !a.busy.get() && a.create.is_visible()
    });
    a.create.emit_clicked();
    let dialog = alert(&a, "Create a Snippets Library Here?");
    press_response(&dialog, "Create Encrypted Library");
    let dialog = alert(&a, "Save Your Recovery Code");
    let code = dialog
        .extra_child()
        .and_then(|c| c.downcast::<gtk::Label>().ok())
        .map(|l| l.label().to_string())
        .unwrap();
    assert_eq!(code.len(), 33);
    assert!(
        a.token.text().is_empty(),
        "the token entry is cleared after use"
    );
    press_response(&dialog, "I’ve Saved It");
    wait_status(&a, "Up to date.");
    assert!(a.connected_group.is_visible() && a.automatic.is_active());
    assert!(secret_present(&root_a, Slot::GitCredential));
    assert!(secret_present(&root_a, Slot::GitLibraryKeys));
    assert!(
        !contains(&root_a, token.as_bytes()),
        "the token is only in the keyring"
    );
    assert!(
        !contains(&root_a, code.as_bytes()),
        "the recovery code is never stored"
    );

    // Device B joins with the code and receives A's snippet.
    let b = GitWindow::new(
        &application,
        &parent,
        Rc::new(Worker::spawn(root_b.clone())),
    );
    b.window.present();
    b.refresh();
    fill(&b, &url, &username, &token);
    b.check.emit_clicked();
    until("library was not offered", || {
        !b.busy.get() && b.join.is_visible()
    });
    assert!(b.code.is_visible());
    b.code.set_text("0000-0000-0000-0000-0000-0000-000");
    b.join.emit_clicked();
    until("a wrong code was not refused", || {
        !b.busy.get() && b.status.label().as_str() != "Connecting…"
    });
    assert!(Settings::read(&root_b).unwrap().is_none());
    fill(&b, &url, &username, &token);
    b.check.emit_clicked();
    until("library was not offered again", || {
        !b.busy.get() && b.join.is_visible()
    });
    b.code.set_text(&code.to_lowercase().replace('-', " "));
    b.join.emit_clicked();
    wait_status(&b, "Up to date.");
    let snippets = Library::open(root_b.clone()).unwrap().snippets;
    assert!(
        snippets
            .iter()
            .any(|s| s.keyword == "linux-git" && s.content == "linux-git-window-initial-3a7e")
    );

    // A deletes it; both devices review the deletion in the window.
    let mut library = Library::open(root_a.clone()).unwrap();
    let snippet = library
        .snippets
        .iter()
        .find(|s| s.keyword == "linux-git")
        .unwrap()
        .clone();
    library.delete(&snippet).unwrap();
    for window in [&a, &b] {
        window.sync_now.emit_clicked();
        until("deletion review was not offered", || {
            !window.busy.get() && window.review.is_visible()
        });
        window.review.emit_clicked();
        let dialog = alert(window, "Review Snippet Deletion");
        press_response(&dialog, "Delete Everywhere");
        wait_status(window, "Up to date.");
        assert!(!window.review.is_visible());
    }
    assert!(Library::open(root_b.clone()).unwrap().snippets.is_empty());

    // Disconnect forgets the token, keeps the key.
    b.disconnect.emit_clicked();
    let dialog = alert(&b, "Remove from This Computer?");
    press_response(&dialog, "Remove");
    until("disconnect did not finish", || {
        !b.busy.get() && !b.connected_group.is_visible()
    });
    assert!(!secret_present(&root_b, Slot::GitCredential));
    assert!(secret_present(&root_b, Slot::GitLibraryKeys));

    // A plain-text library: the window asks which kind to create, shows the
    // mode, and asks before another device joins it.
    let plain_url = std::env::var("SNIPPETS_GIT_LIVE_HTTP_PLAIN_URL").unwrap();
    let plain_repo = std::env::var("SNIPPETS_GIT_LIVE_PLAIN_REPO").unwrap();
    assert!(plain_repo.starts_with("/tmp/"));
    let root_c = data.join("device-c/snippets");
    let root_d = data.join("device-d/snippets");
    let mut seed = crate::model::Snippet::new("Plain Window", "plain-window-body-8d31");
    seed.keyword = "plain-window".into();
    Library::open(root_c.clone())
        .unwrap()
        .save(seed, None)
        .unwrap();
    Library::open(root_d.clone()).unwrap();
    let c = GitWindow::new(
        &application,
        &parent,
        Rc::new(Worker::spawn(root_c.clone())),
    );
    c.window.present();
    c.refresh();
    fill(&c, &plain_url, &username, &token);
    c.check.emit_clicked();
    until("the empty plain branch was not offered", || {
        !c.busy.get() && c.create.is_visible()
    });
    c.create.emit_clicked();
    let dialog = alert(&c, "Create a Snippets Library Here?");
    let body = dialog.body();
    for shared in [
        "Encrypted (recommended): the host and anyone with access to the repository see only unreadable files.",
        "Plain text: ordinary snippets become Markdown files that the host and anyone with access can read, and they stay in the repository’s history even after you delete them. Secure snippets are always encrypted.",
        "You can’t change this later.",
    ] {
        assert!(body.contains(shared), "{shared}");
    }
    assert_eq!(dialog.default_response().as_deref(), Some("encrypted"));
    press_response(&dialog, "Create Plain-Text Library");
    let dialog = alert(&c, "Save Your Recovery Code");
    let plain_code = dialog
        .extra_child()
        .and_then(|c| c.downcast::<gtk::Label>().ok())
        .map(|l| l.label().to_string())
        .unwrap();
    press_response(&dialog, "I’ve Saved It");
    wait_status(&c, "Up to date.");
    assert_eq!(
        Settings::read(&root_c).unwrap().unwrap().mode,
        Mode::PlainText
    );
    assert!(
        c.connected_group
            .description()
            .unwrap()
            .contains(git_setup::PLAIN_TEXT_STATUS)
    );
    let files = crate::git_tests::plain_git_ok(&[
        "--git-dir",
        &plain_repo,
        "ls-tree",
        "-r",
        "--name-only",
        "main",
    ]);
    let file = files
        .lines()
        .find(|f| f.starts_with("snippets/plain-window-"))
        .unwrap();
    assert!(
        crate::git_tests::plain_git_ok(&[
            "--git-dir",
            &plain_repo,
            "show",
            &format!("main:{file}")
        ])
        .ends_with("\n---\nplain-window-body-8d31\n")
    );

    let d = GitWindow::new(
        &application,
        &parent,
        Rc::new(Worker::spawn(root_d.clone())),
    );
    d.window.present();
    d.refresh();
    fill(&d, &plain_url, &username, &token);
    d.check.emit_clicked();
    until("the plain library was not offered", || {
        !d.busy.get() && d.join.is_visible()
    });
    assert!(d.result.label().contains(git_setup::PLAIN_TEXT_STATUS));
    d.code.set_text(&plain_code);
    d.join.emit_clicked();
    let dialog = alert(&d, "Join a Plain-Text Library?");
    press_response(&dialog, "Cancel");
    until("cancelling the consent must not connect", || !d.busy.get());
    assert!(Settings::read(&root_d).unwrap().is_none());
    d.code.set_text(&plain_code);
    d.join.emit_clicked();
    let dialog = alert(&d, "Join a Plain-Text Library?");
    press_response(&dialog, "Join");
    wait_status(&d, "Up to date.");
    assert!(
        Library::open(root_d.clone())
            .unwrap()
            .snippets
            .iter()
            .any(|s| s.keyword == "plain-window" && s.content == "plain-window-body-8d31")
    );

    for window in [&a, &b, &c, &d] {
        window.worker.cancel.store(true, Ordering::SeqCst);
        window.window.close();
    }
    parent.close();
}

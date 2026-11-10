//! Git Sync window and its background owner (primary desktop process only).
//! Blocking git and keyring work runs on one worker thread; the GTK thread
//! only polls replies. Tokens and recovery codes are read from entries once
//! and cleared; nothing here logs.
use crate::{
    auto_sync::{Outcome, Schedule, Wake},
    deletion_review::{Choice, Kind},
    git_layout::Mode,
    git_location::Location,
    git_setup::{
        self, DeletionSummary, Environment, Failure, Form, Inspection, Settings, State, SyncReport,
        SyncState,
    },
    secret_store::{Native, Store},
    snapshot_review,
};
use adw::prelude::*;
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use uuid::Uuid;
use zeroize::Zeroizing;

// MARK: - Worker

enum Request {
    Inspect(Form),
    /// The last field is the user's word that the repository is private
    /// when Snippets could not check it.
    Create(Form, Mode, bool),
    /// The library and the mode the user saw; the last field is the user's
    /// consent to joining a plain-text library.
    Join(Form, Uuid, Mode, Option<Zeroizing<String>>, bool),
    Sync,
    DeletionReview(Option<Choice>),
    SnapshotReview(bool),
    ReplaceRecovery,
    Automatic(bool),
    Disconnect,
}
enum Reply {
    Inspected(Inspection),
    Created(Zeroizing<String>),
    CreateFailed(Failure, Option<Zeroizing<String>>),
    Done,
    Synced(SyncReport),
    Deletion(DeletionSummary),
    Snapshot(snapshot_review::Summary),
    RecoveryCode(Zeroizing<String>),
    Failed(Failure),
}
enum Message {
    Task(Request, mpsc::SyncSender<Reply>),
    Wake(Wake),
}
/// The last outcome, for the window. Counts and closed states only.
#[derive(Clone, Copy, Default)]
struct Last {
    result: Option<Result<SyncReport, Failure>>,
    running: bool,
}
pub(crate) struct Worker {
    root: PathBuf,
    sender: mpsc::Sender<Message>,
    cancel: Arc<AtomicBool>,
    last: Arc<Mutex<Last>>,
}
thread_local! {
    static WORKER: RefCell<Option<Rc<Worker>>> = const { RefCell::new(None) };
    static WINDOW: RefCell<Option<Rc<GitWindow>>> = const { RefCell::new(None) };
}
/// Starts the owner once, in the primary process.
pub(crate) fn start(root: PathBuf) {
    WORKER.with(|cell| {
        if cell.borrow().is_none() {
            *cell.borrow_mut() = Some(Rc::new(Worker::spawn(root)));
        }
    });
}
pub(crate) fn wake(reason: Wake) {
    WORKER.with(|cell| {
        if let Some(worker) = cell.borrow().as_ref() {
            let _ = worker.sender.send(Message::Wake(reason));
        }
    });
}
/// Quitting cancels in-flight git (its process group is killed). A cut cycle
/// is safe: the journal is written first and every push is compare-and-swap.
pub(crate) fn shutdown() {
    WORKER.with(|cell| {
        if let Some(worker) = cell.borrow().as_ref() {
            worker.cancel.store(true, Ordering::SeqCst);
        }
    });
}
pub(crate) fn present(
    application: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: PathBuf,
) {
    start(root);
    let Some(worker) = WORKER.with(|cell| cell.borrow().clone()) else {
        return;
    };
    let window = WINDOW.with(|cell| {
        cell.borrow_mut()
            .get_or_insert_with(|| GitWindow::new(application, parent, worker))
            .clone()
    });
    window.window.present();
    window.refresh();
}

impl Worker {
    fn spawn(root: PathBuf) -> Self {
        let (sender, receiver) = mpsc::channel::<Message>();
        let cancel = Arc::new(AtomicBool::new(false));
        let last = Arc::new(Mutex::new(Last::default()));
        let environment = Environment::new(root.clone()).with_cancel(cancel.clone());
        let shared = last.clone();
        let stop = cancel.clone();
        std::thread::Builder::new()
            .name("snippets-git-sync".into())
            .spawn(move || run(environment, receiver, shared, stop))
            .expect("git sync worker thread");
        Self {
            root,
            sender,
            cancel,
            last,
        }
    }
    fn request(&self, request: Request) -> Option<mpsc::Receiver<Reply>> {
        let (reply, receiver) = mpsc::sync_channel(1);
        self.sender.send(Message::Task(request, reply)).ok()?;
        Some(receiver)
    }
    fn last(&self) -> Last {
        *self.last.lock().unwrap()
    }
}
fn store(root: &std::path::Path) -> Result<Store<Native>, Failure> {
    // A test storage override never reaches the login keyring.
    Ok(Store::initialize(root, Native::new()?)?)
}
fn run(
    environment: Environment,
    receiver: mpsc::Receiver<Message>,
    last: Arc<Mutex<Last>>,
    cancel: Arc<AtomicBool>,
) {
    let started = Instant::now();
    let mut schedule = Schedule::new(Duration::ZERO);
    let sync = |last: &Mutex<Last>| {
        last.lock().unwrap().running = true;
        let result = store(&environment.root)
            .and_then(|mut store| git_setup::synchronize(&environment, &mut store));
        let mut state = last.lock().unwrap();
        state.running = false;
        state.result = Some(result);
        result
    };
    loop {
        if cancel.load(Ordering::SeqCst) {
            return;
        }
        match receiver.recv_timeout(Duration::from_secs(1)) {
            Ok(Message::Wake(reason)) => schedule.wake(reason, started.elapsed()),
            Ok(Message::Task(request, reply)) => {
                let response = match request {
                    Request::Inspect(form) => store(&environment.root)
                        .and_then(|mut s| git_setup::inspect(&environment, &mut s, &form))
                        .map_or_else(Reply::Failed, Reply::Inspected),
                    Request::Create(form, mode, confirmed_private) => {
                        match store(&environment.root) {
                            Err(failure) => Reply::Failed(failure),
                            Ok(mut s) => match git_setup::create(
                                &environment,
                                &mut s,
                                &form,
                                mode,
                                confirmed_private,
                            ) {
                                Ok(code) => Reply::Created(code),
                                Err((failure, code)) => Reply::CreateFailed(failure, code),
                            },
                        }
                    }
                    Request::Join(form, dataset, mode, code, accept_plain_text) => {
                        store(&environment.root)
                            .and_then(|mut s| {
                                git_setup::join(
                                    &environment,
                                    &mut s,
                                    &form,
                                    dataset,
                                    mode,
                                    code.as_deref().map(String::as_str),
                                    accept_plain_text,
                                )
                            })
                            .map_or_else(Reply::Failed, |()| Reply::Done)
                    }
                    Request::Sync => sync(&last).map_or_else(Reply::Failed, Reply::Synced),
                    Request::DeletionReview(choice) => store(&environment.root)
                        .and_then(|mut s| git_setup::deletion_review(&environment, &mut s, choice))
                        .map_or_else(Reply::Failed, Reply::Deletion),
                    Request::SnapshotReview(confirm) => store(&environment.root)
                        .and_then(|mut s| {
                            git_setup::resolve_snapshot_review(&environment, &mut s, confirm)
                        })
                        .map_or_else(Reply::Failed, Reply::Snapshot),
                    Request::ReplaceRecovery => store(&environment.root)
                        .and_then(|mut s| git_setup::replace_recovery_code(&environment, &mut s))
                        .map_or_else(Reply::Failed, Reply::RecoveryCode),
                    Request::Automatic(on) => git_setup::set_automatic(&environment, on)
                        .map_or_else(Reply::Failed, |()| Reply::Done),
                    Request::Disconnect => store(&environment.root)
                        .and_then(|mut s| git_setup::disconnect(&environment, &mut s))
                        .map_or_else(Reply::Failed, |()| Reply::Done),
                };
                // Any explicit action re-arms automatic sync after a halt.
                schedule = Schedule::new(started.elapsed() + Duration::from_secs(2));
                let _ = reply.send(response);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let automatic = Settings::read(&environment.root)
                    .ok()
                    .flatten()
                    .is_some_and(|s| s.automatic);
                if !automatic || !schedule.begin(started.elapsed()) {
                    continue;
                }
                // Only a failure that needs the person halts automatic sync;
                // a halted schedule ignores wakes until an explicit action.
                let outcome = match sync(&last) {
                    Ok(report) => report.state.automatic(),
                    Err(failure) if transient(failure) => Outcome::Retry,
                    Err(_) => Outcome::Attention,
                };
                schedule.finish(outcome, started.elapsed());
            }
        }
    }
}
/// Failures that clear on their own, as in the Cloud worker: the network, a
/// busy or locked keyring, the library being changed elsewhere, and a cache
/// that is still unusable after one rebuild.
fn transient(failure: Failure) -> bool {
    use crate::git_repo::Failure as G;
    use crate::git_transport::Failure as T;
    use crate::secret_store::Failure as S;
    matches!(
        failure,
        Failure::Transport(
            T::Git(G::Unreachable | G::RateLimited | G::Cancelled | G::LocalStorage)
                | T::Contended
                | T::SnapshotIncomplete
        ) | Failure::Secret(S::Locked | S::Unavailable | S::Timeout)
            | Failure::LibraryBusy
            | Failure::Interrupted
    )
}

// MARK: - Window

struct GitWindow {
    window: adw::ApplicationWindow,
    worker: Rc<Worker>,
    busy: Cell<bool>,
    inspected: RefCell<Option<Inspection>>,
    status: gtk::Label,
    connected_group: adw::PreferencesGroup,
    sync_now: gtk::Button,
    automatic: adw::SwitchRow,
    review: gtk::Button,
    recovery: gtk::Button,
    disconnect: gtk::Button,
    connect_group: adw::PreferencesGroup,
    repository: adw::EntryRow,
    branch: adw::EntryRow,
    username: adw::EntryRow,
    token: adw::PasswordEntryRow,
    token_help: gtk::Label,
    ssh_hint: gtk::Label,
    check: gtk::Button,
    result: gtk::Label,
    use_branch: gtk::Button,
    code: adw::PasswordEntryRow,
    create: gtk::Button,
    join: gtk::Button,
}
fn label(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.set_xalign(0.0);
    label.set_wrap(true);
    label
}
fn take(entry: &impl IsA<gtk::Editable>) -> Zeroizing<String> {
    let text = Zeroizing::new(entry.text().to_string());
    entry.set_text("");
    text
}
fn looks_like_ssh(text: &str) -> bool {
    Location::parse(text, true).map_or_else(
        |_| {
            let text = text.trim();
            text.starts_with("ssh://")
                || text.starts_with("git+ssh://")
                || text
                    .split_once(':')
                    .is_some_and(|(head, _)| !head.contains('/'))
                    && !text.contains("://")
        },
        |l| l.is_ssh(),
    )
}
impl GitWindow {
    fn new(
        application: &adw::Application,
        parent: &adw::ApplicationWindow,
        worker: Rc<Worker>,
    ) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(application)
            .transient_for(parent)
            .title("Git Repository")
            .default_width(560)
            .default_height(720)
            .build();
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 0);
        window.set_content(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Git Repository",
            "Your own repository",
        )));
        layout.append(&header);
        let page = adw::PreferencesPage::new();
        page.set_vexpand(true);
        layout.append(&page);

        let intro = adw::PreferencesGroup::new();
        intro.add(&label("Sync this library through a git repository you own on GitHub, GitLab, Gitea, GitVerse or any git host. Snippets talks to the host directly; there is no Snippets server. An encrypted library gives the host only end-to-end encrypted records; a plain-text library keeps ordinary snippets as readable Markdown files you can browse and edit in the repository."));
        let status = label("No Git repository is connected on this device.");
        status.set_margin_top(12);
        intro.add(&status);
        page.add(&intro);

        let connected_group = adw::PreferencesGroup::builder()
            .title("Connected Library")
            .build();
        let automatic = adw::SwitchRow::builder()
            .title("Automatic Sync")
            .subtitle("Check for changes in the background while Snippets runs")
            .build();
        connected_group.add(&automatic);
        let actions = gtk::Box::new(gtk::Orientation::Vertical, 8);
        actions.set_margin_top(12);
        let sync_now = gtk::Button::with_label("Sync Now");
        sync_now.add_css_class("suggested-action");
        let review = gtk::Button::with_label("Review…");
        review.set_visible(false);
        let recovery = gtk::Button::with_label("New Recovery Code…");
        let disconnect = gtk::Button::with_label("Remove from This Computer…");
        disconnect.add_css_class("destructive-action");
        for button in [&sync_now, &review, &recovery, &disconnect] {
            actions.append(button);
        }
        connected_group.add(&actions);
        page.add(&connected_group);

        let connect_group = adw::PreferencesGroup::builder()
            .title("Connect a Repository")
            .description(
                "Create a new private repository without a README, then paste its address.",
            )
            .build();
        let repository = adw::EntryRow::builder().title("Repository").build();
        repository.set_input_purpose(gtk::InputPurpose::Url);
        let branch = adw::EntryRow::builder()
            .title("Branch")
            .text("main")
            .build();
        let username = adw::EntryRow::builder().title("User Name").build();
        let token = adw::PasswordEntryRow::builder()
            .title("Access Token")
            .build();
        let ssh_hint = label(
            "SSH uses your ssh-agent, ~/.ssh/config and ~/.ssh/known_hosts. No token is stored. If the host is new, connect once with ssh in a terminal to verify its key first.",
        );
        ssh_hint.add_css_class("dim-label");
        ssh_hint.set_margin_top(8);
        ssh_hint.set_visible(false);
        let token_help = label("");
        token_help.add_css_class("dim-label");
        token_help.set_margin_top(8);
        token_help.set_use_markup(true);
        for row in [&repository, &branch, &username] {
            connect_group.add(row);
        }
        connect_group.add(&token);
        connect_group.add(&token_help);
        connect_group.add(&ssh_hint);
        let check = gtk::Button::with_label("Check Repository");
        check.set_margin_top(12);
        connect_group.add(&check);
        let result = label("");
        result.set_margin_top(8);
        result.set_visible(false);
        connect_group.add(&result);
        let use_branch = gtk::Button::with_label("Use Branch “snippets”");
        use_branch.set_margin_top(8);
        use_branch.set_visible(false);
        connect_group.add(&use_branch);
        let code = adw::PasswordEntryRow::builder()
            .title("Recovery Code")
            .build();
        code.set_visible(false);
        connect_group.add(&code);
        let create = gtk::Button::with_label("Create Library");
        create.add_css_class("suggested-action");
        create.set_visible(false);
        let join = gtk::Button::with_label("Connect to Library");
        join.add_css_class("suggested-action");
        join.set_visible(false);
        connect_group.add(&create);
        connect_group.add(&join);
        page.add(&connect_group);

        let this = Rc::new(Self {
            window,
            worker,
            busy: Cell::new(false),
            inspected: RefCell::new(None),
            status,
            connected_group,
            sync_now,
            automatic,
            review,
            recovery,
            disconnect,
            connect_group,
            repository,
            branch,
            username,
            token,
            token_help,
            ssh_hint,
            check,
            result,
            use_branch,
            code,
            create,
            join,
        });
        this.wire();
        this.update_host_help();
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_secs(1), move || match weak.upgrade() {
            Some(this) if this.window.is_visible() => {
                if !this.busy.get() {
                    this.show_last();
                }
                glib::ControlFlow::Continue
            }
            Some(_) => glib::ControlFlow::Continue,
            None => glib::ControlFlow::Break,
        });
        this
    }
    fn wire(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.repository.connect_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.forget_inspection();
                this.update_host_help();
            }
        });
        let weak = Rc::downgrade(self);
        self.use_branch.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.branch.set_text("snippets");
                this.inspect();
            }
        });
        for entry in [&self.branch, &self.username] {
            let weak = Rc::downgrade(self);
            entry.connect_changed(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.forget_inspection();
                }
            });
        }
        let weak = Rc::downgrade(self);
        self.check.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.inspect();
            }
        });
        let weak = Rc::downgrade(self);
        self.create.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.create().await });
            }
        });
        let weak = Rc::downgrade(self);
        self.join.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.join().await });
            }
        });
        let weak = Rc::downgrade(self);
        self.sync_now.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.sync().await });
            }
        });
        let weak = Rc::downgrade(self);
        self.automatic.connect_active_notify(move |row| {
            if let Some(this) = weak.upgrade() {
                let on = row.is_active();
                let current = Settings::read(&this.worker.root)
                    .ok()
                    .flatten()
                    .map(|s| s.automatic);
                if current.is_some_and(|c| c != on) {
                    glib::spawn_future_local(async move {
                        match this.execute(Request::Automatic(on)).await {
                            Reply::Failed(failure) => this.status.set_label(failure.message()),
                            _ => this.refresh(),
                        }
                    });
                }
            }
        });
        let weak = Rc::downgrade(self);
        self.review.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.review().await });
            }
        });
        let weak = Rc::downgrade(self);
        self.recovery.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.replace_recovery().await });
            }
        });
        let weak = Rc::downgrade(self);
        self.disconnect.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.disconnect().await });
            }
        });
    }
    async fn execute(&self, request: Request) -> Reply {
        let Some(receiver) = self.worker.request(request) else {
            return Reply::Failed(Failure::Interrupted);
        };
        self.set_busy(true);
        let reply = loop {
            match receiver.try_recv() {
                Ok(reply) => break reply,
                Err(mpsc::TryRecvError::Disconnected) => break Reply::Failed(Failure::Interrupted),
                Err(mpsc::TryRecvError::Empty) => {
                    glib::timeout_future(Duration::from_millis(40)).await
                }
            }
        };
        self.set_busy(false);
        reply
    }
    fn set_busy(&self, busy: bool) {
        self.busy.set(busy);
        for button in [
            &self.check,
            &self.create,
            &self.join,
            &self.sync_now,
            &self.review,
            &self.recovery,
            &self.disconnect,
        ] {
            button.set_sensitive(!busy);
        }
        self.automatic.set_sensitive(!busy);
    }
    fn settings(&self) -> Option<Settings> {
        Settings::read(&self.worker.root).ok().flatten()
    }
    fn refresh(&self) {
        let settings = self.settings();
        self.connected_group.set_visible(settings.is_some());
        if let Some(settings) = &settings {
            let environment = Environment::new(self.worker.root.clone());
            let ssh = settings
                .remote(&environment)
                .is_ok_and(|r| r.location.is_ssh());
            let mut description = format!(
                "{} · {} · {}",
                settings.display_location(&environment),
                settings.branch,
                if ssh { "SSH" } else { "HTTPS" }
            );
            if settings.mode == Mode::PlainText {
                description.push('\n');
                description.push_str(git_setup::PLAIN_TEXT_STATUS);
            }
            self.connected_group.set_description(Some(&description));
            self.automatic.set_active(settings.automatic);
            if self.repository.text().is_empty() {
                self.repository.set_text(&settings.repository);
                self.branch.set_text(&settings.branch);
                if let Some(username) = &settings.username {
                    self.username.set_text(username);
                }
            }
            self.connect_group.set_title("Reconnect or Update Token");
        } else {
            self.connect_group.set_title("Connect a Repository");
            self.status
                .set_label("No Git repository is connected on this device.");
        }
        self.show_last();
    }
    fn show_last(&self) {
        if self.settings().is_none() {
            self.review.set_visible(false);
            return;
        }
        let last = self.worker.last();
        let text = match last.result {
            _ if last.running => "Syncing…".to_owned(),
            None => "Connected. Press Sync Now, or leave Automatic Sync on.".to_owned(),
            Some(Ok(report)) => {
                let mut text = report.state.message().to_owned();
                if report.received + report.accepted > 0 {
                    text.push_str(&format!(
                        " Received {}, sent {}.",
                        report.applied, report.accepted
                    ));
                }
                if let Some(warning) = report.warning() {
                    text.push(' ');
                    text.push_str(&warning);
                }
                text
            }
            Some(Err(failure)) => failure.message().to_owned(),
        };
        self.status.set_label(&text);
        self.review.set_visible(matches!(
            last.result,
            Some(Ok(SyncReport {
                state: SyncState::DeletionReview | SyncState::SnapshotReview,
                ..
            }))
        ));
    }
    /// SSH or HTTPS fields, and for HTTPS how to make a token on this host
    /// and whether a user name is needed (as on Apple).
    fn update_host_help(&self) {
        let text = self.repository.text();
        let ssh = looks_like_ssh(&text);
        self.username.set_visible(!ssh);
        self.token.set_visible(!ssh);
        self.ssh_hint.set_visible(ssh);
        let check = Location::parse(&text, false)
            .ok()
            .and_then(|location| location.ssh_test_command())
            .unwrap_or_else(|| "ssh -T with the address’s user and host".into());
        self.ssh_hint.set_label(&format!(
            "Connects with the system ssh, using your ssh-agent and ~/.ssh/config. The host must already be in known_hosts and accept a key from your agent: check with {check} in a terminal. Snippets stores no SSH key or password."
        ));
        self.token_help.set_visible(!ssh);
        let host = Location::parse(&text, true)
            .map_or(git_setup::Host::Other, |l| git_setup::Host::of(&l));
        self.username.set_title(match host {
            git_setup::Host::GitHub | git_setup::Host::GitLab => "User Name (optional)",
            git_setup::Host::Other => "User Name",
        });
        let (help, link) = git_setup::token_help(&text);
        let mut markup = glib::markup_escape_text(&help).to_string();
        if let Some(link) = link {
            markup.push_str(&format!(
                " <a href=\"{}\">Open the token page</a>",
                glib::markup_escape_text(&link)
            ));
        }
        self.token_help.set_markup(&markup);
    }
    fn forget_inspection(&self) {
        self.inspected.borrow_mut().take();
        self.use_branch.set_visible(false);
        self.result.set_visible(false);
        self.code.set_visible(false);
        self.create.set_visible(false);
        self.join.set_visible(false);
    }
    fn form(&self) -> Form {
        let ssh = looks_like_ssh(&self.repository.text());
        Form {
            repository: self.repository.text().to_string(),
            branch: self.branch.text().trim().to_owned(),
            username: if ssh {
                String::new()
            } else {
                self.username.text().trim().to_owned()
            },
            token: if ssh {
                Zeroizing::new(String::new())
            } else {
                Zeroizing::new(self.token.text().to_string())
            },
        }
    }
    fn inspect(self: &Rc<Self>) {
        let this = self.clone();
        glib::spawn_future_local(async move {
            this.forget_inspection();
            this.status.set_label("Checking the repository…");
            let reply = this.execute(Request::Inspect(this.form())).await;
            this.result.set_visible(true);
            match reply {
                Reply::Inspected(inspection) => {
                    match inspection.state {
                        State::Empty => {
                            this.result.set_label("This branch is empty. Create a new library here; you will get a recovery code for your other devices.");
                            this.create.set_visible(true);
                        }
                        State::Foreign => {
                            this.result.set_label(Failure::ForeignBranch.message());
                            this.use_branch
                                .set_visible(this.branch.text().trim() != "snippets");
                        }
                        State::Library {
                            mode,
                            key_available,
                            recovery_available,
                            ..
                        } => {
                            let kind = match mode {
                                Mode::Encrypted => String::new(),
                                Mode::PlainText => format!(" {}", git_setup::PLAIN_TEXT_STATUS),
                            };
                            if key_available {
                                this.result.set_label(&format!("This repository holds a Snippets library this device can already open.{kind}"));
                            } else if recovery_available {
                                this.result.set_label(&format!("This repository holds a Snippets library. Enter its recovery code to connect.{kind}"));
                                this.code.set_visible(true);
                            } else {
                                this.result
                                    .set_label(Failure::RecoveryUnavailable.message());
                            }
                            this.join.set_visible(key_available || recovery_available);
                        }
                    }
                    *this.inspected.borrow_mut() = Some(inspection);
                    this.refresh();
                }
                Reply::Failed(failure) => {
                    this.result.set_label(failure.message());
                    this.refresh();
                }
                _ => (),
            }
        });
    }
    /// Connecting where this device already syncs another library replaces
    /// its sync state after explicit confirmation; snippets are kept.
    async fn confirm_switch(&self) -> bool {
        let replaces = self
            .inspected
            .borrow()
            .as_ref()
            .is_some_and(|i| i.replaces_sync_state);
        if !replaces {
            return true;
        }
        let dialog = adw::AlertDialog::builder()
            .heading("Replace This Device’s Sync State?")
            .body("This device currently syncs another library. Your snippets stay on this device and are merged into the Git library; the previous sync state is retained for review. Continue?")
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("continue", "Continue")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.choose_future(Some(&self.window)).await == "continue"
    }
    /// Encrypted or plain text, chosen once for the library's lifetime.
    async fn choose_mode(&self) -> Option<Mode> {
        let dialog = adw::AlertDialog::builder()
            .heading("Create a Snippets Library Here?")
            .body("This branch is empty. Snippets will create a library there with a new key and show you a recovery code for setting up other devices.\n\nEncrypted (recommended): the host and anyone with access to the repository see only unreadable files.\n\nPlain text: ordinary snippets become Markdown files that the host and anyone with access can read, and they stay in the repository’s history even after you delete them. Secure snippets are always encrypted.\n\nYou can’t change this later.")
            .build();
        dialog.add_responses(&[
            ("cancel", "Cancel"),
            ("plain", "Create Plain-Text Library"),
            ("encrypted", "Create Encrypted Library"),
        ]);
        dialog.set_response_appearance("encrypted", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("encrypted"));
        dialog.set_close_response("cancel");
        match dialog.choose_future(Some(&self.window)).await.as_str() {
            "encrypted" => Some(Mode::Encrypted),
            "plain" => Some(Mode::PlainText),
            _ => None,
        }
    }
    /// Whether the user says the repository is private, when Snippets could
    /// not check it. Wording shared with Apple.
    async fn confirm_private(&self) -> bool {
        let dialog = adw::AlertDialog::builder()
            .heading(git_setup::VISIBILITY_UNKNOWN_TITLE)
            .body(git_setup::VISIBILITY_UNKNOWN_MESSAGE)
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("private", "It’s Private")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.choose_future(Some(&self.window)).await == "private"
    }
    /// Joining a plain-text library makes this device's ordinary snippets
    /// readable in the repository; ask first.
    async fn confirm_plain_text_join(&self) -> bool {
        let dialog = adw::AlertDialog::builder()
            .heading("Join a Plain-Text Library?")
            .body("This library stores ordinary snippets as readable Markdown files. After you connect, this device’s ordinary snippets will be readable by anyone with access to the repository, and stay in its history. Secure snippets stay encrypted.")
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("join", "Join")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.choose_future(Some(&self.window)).await == "join"
    }
    async fn create(self: &Rc<Self>) {
        if !self.confirm_switch().await {
            return;
        }
        let Some(mode) = self.choose_mode().await else {
            return;
        };
        let form = self.form();
        self.token.set_text("");
        self.status.set_label("Creating the library…");
        let mut reply = self
            .execute(Request::Create(form.clone(), mode, false))
            .await;
        // Snippets could not tell whether the repository is private: plain
        // text goes ahead only on the user's word.
        if matches!(reply, Reply::CreateFailed(Failure::VisibilityUnknown, None)) {
            if !self.confirm_private().await {
                self.status.set_label("");
                return;
            }
            self.status.set_label("Creating the library…");
            reply = self.execute(Request::Create(form, mode, true)).await;
        }
        match reply {
            Reply::Created(code) => {
                self.forget_inspection();
                self.refresh();
                self.show_code("Save Your Recovery Code", "Another device needs this code once to join the library. Keep it somewhere safe: it is not stored anywhere readable, and without it a new device cannot open the library.", code).await;
                self.sync().await;
            }
            Reply::CreateFailed(failure, Some(code)) => {
                self.status.set_label(failure.message());
                self.show_code("Keep This Recovery Code", "Snippets could not confirm every step. The library may exist: this code opens it. Keep it, then check the repository again.", code).await;
            }
            Reply::CreateFailed(failure, None) | Reply::Failed(failure) => {
                self.status.set_label(failure.message());
                if matches!(
                    failure,
                    Failure::ForeignBranch
                        | Failure::Transport(crate::git_transport::Failure::NotALibrary)
                ) {
                    self.use_branch
                        .set_visible(self.branch.text().trim() != "snippets");
                }
            }
            _ => (),
        }
    }
    async fn join(self: &Rc<Self>) {
        let Some(Inspection {
            state:
                State::Library {
                    dataset,
                    mode,
                    key_available,
                    ..
                },
            ..
        }) = *self.inspected.borrow()
        else {
            return;
        };
        let consent = git_setup::joining_needs_consent(
            &Environment::new(self.worker.root.clone()),
            &self.form(),
            dataset,
            mode,
        );
        if consent && !self.confirm_plain_text_join().await {
            return;
        }
        if !self.confirm_switch().await {
            return;
        }
        let code = (!key_available).then(|| take(&self.code));
        let form = self.form();
        self.token.set_text("");
        self.status.set_label("Connecting…");
        match self
            .execute(Request::Join(form, dataset, mode, code, consent))
            .await
        {
            Reply::Done => {
                self.forget_inspection();
                self.refresh();
                self.sync().await;
            }
            Reply::Failed(failure) => {
                self.status.set_label(failure.message());
                if matches!(
                    failure,
                    Failure::IncorrectRecoveryCode | Failure::InvalidRecoveryCode
                ) {
                    self.code.set_visible(true);
                }
            }
            _ => (),
        }
    }
    async fn sync(self: &Rc<Self>) {
        for _ in 0..8 {
            match self.execute(Request::Sync).await {
                Reply::Synced(report)
                    if matches!(
                        report.state,
                        SyncState::MoreWork | SyncState::PrimaryChanged
                    ) =>
                {
                    continue;
                }
                _ => break,
            }
        }
        self.refresh();
    }
    async fn review(self: &Rc<Self>) {
        let state = match self.worker.last().result {
            Some(Ok(report)) => report.state,
            _ => return,
        };
        if state == SyncState::SnapshotReview {
            let Reply::Snapshot(summary) = self.execute(Request::SnapshotReview(false)).await
            else {
                return self.refresh();
            };
            let dialog = adw::AlertDialog::builder()
                .heading("Keep This Device’s Snippets?")
                .body(format!(
                    "{} synchronized snippets are missing from the repository. Snippets keeps this device’s {} snippets and uploads them again. Nothing is deleted.",
                    summary.missing_records, summary.local_records
                ))
                .build();
            dialog.add_responses(&[("cancel", "Cancel"), ("keep", "Keep and Continue")]);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            if dialog.choose_future(Some(&self.window)).await == "keep" {
                if let Reply::Failed(failure) = self.execute(Request::SnapshotReview(true)).await {
                    self.status.set_label(failure.message());
                    return;
                }
                self.sync().await;
            }
            return;
        }
        let Reply::Deletion(summary) = self.execute(Request::DeletionReview(None)).await else {
            return self.refresh();
        };
        let what = match summary.kind {
            Kind::CloudDeletion => "Another device deleted this snippet.",
            Kind::LocalAbsence => "This snippet is missing from this device's library.",
            Kind::PendingDeletion => "A deletion of this snippet is waiting to sync.",
        };
        let name = if summary.keyword.is_empty() {
            summary.name.clone()
        } else {
            format!("{} · {}", summary.name, summary.keyword)
        };
        let dialog = adw::AlertDialog::builder()
            .heading("Review Snippet Deletion")
            .body(format!("{name}\n\n{what}"))
            .build();
        dialog.add_responses(&[
            ("cancel", "Cancel"),
            ("keep", "Keep Snippet"),
            ("delete", "Delete Everywhere"),
        ]);
        dialog.set_response_enabled("keep", summary.can_keep && !summary.secure);
        dialog.set_response_enabled("delete", !summary.secure);
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        if summary.secure {
            self.status
                .set_label("Secure snippet deletions are reviewed in Account & Recovery.");
        }
        let choice = match dialog.choose_future(Some(&self.window)).await.as_str() {
            "delete" => Choice::Delete,
            "keep" => Choice::Keep,
            _ => return,
        };
        if let Reply::Failed(failure) = self.execute(Request::DeletionReview(Some(choice))).await {
            self.status.set_label(failure.message());
            return;
        }
        self.sync().await;
    }
    async fn replace_recovery(self: &Rc<Self>) {
        let dialog = adw::AlertDialog::builder()
            .heading("Create a New Recovery Code?")
            .body("Your old code stops working in Snippets. Someone who already has it and can read the repository’s history could still decrypt the library. To fully revoke a code, create a new library.")
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("replace", "Create New Code")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        if dialog.choose_future(Some(&self.window)).await != "replace" {
            return;
        }
        match self.execute(Request::ReplaceRecovery).await {
            Reply::RecoveryCode(code) => {
                self.show_code(
                    "Save Your New Recovery Code",
                    "New devices join with this code from now on.",
                    code,
                )
                .await
            }
            Reply::Failed(failure) => self.status.set_label(failure.message()),
            _ => (),
        }
        self.refresh();
    }
    async fn disconnect(self: &Rc<Self>) {
        let dialog = adw::AlertDialog::builder()
            .heading("Remove from This Computer?")
            .body("This computer stops syncing with the repository and forgets its access token. Your snippets and the library key stay on this computer, so reconnecting later needs no recovery code.")
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("disconnect", "Remove")]);
        dialog.set_response_appearance("disconnect", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        if dialog.choose_future(Some(&self.window)).await != "disconnect" {
            return;
        }
        if let Reply::Failed(failure) = self.execute(Request::Disconnect).await {
            self.status.set_label(failure.message());
        }
        self.refresh();
    }
    async fn show_code(&self, heading: &str, body: &str, code: Zeroizing<String>) {
        let text = label(&code);
        text.set_selectable(true);
        text.add_css_class("monospace");
        text.add_css_class("title-3");
        text.set_xalign(0.5);
        text.update_property(&[gtk::accessible::Property::Label("Recovery code")]);
        let dialog = adw::AlertDialog::builder()
            .heading(heading)
            .body(body)
            .extra_child(&text)
            .build();
        dialog.add_responses(&[("copy", "Copy"), ("done", "I’ve Saved It")]);
        dialog.set_response_appearance("done", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("done"));
        dialog.set_close_response("done");
        loop {
            let response = dialog.clone().choose_future(Some(&self.window)).await;
            if response != "copy" {
                break;
            }
            if crate::account_ui::copy_account_key(&self.window, &code).is_ok() {
                self.status.set_label("Recovery code copied. Snippets clears it from the clipboard after two minutes if it is still there.");
            }
        }
        text.set_label("");
    }
}

#[cfg(test)]
#[path = "git_ui_live_tests.rs"]
mod live_tests;

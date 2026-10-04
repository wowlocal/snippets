//! Native log controls. All storage work runs off the GTK thread.
use super::*;
use crate::diagnostics_service::{Error as LogError, Service};
use std::sync::Arc;

#[cfg(test)]
#[path = "diagnostics_live_tests.rs"]
mod live_tests;

pub(super) struct Controls {
    pub page: adw::PreferencesPage,
    window: glib::WeakRef<adw::PreferencesWindow>,
    service: Option<Arc<Service>>,
    status: adw::ActionRow,
    export: gtk::Button,
    delete: gtk::Button,
    busy: Cell<bool>,
    quitting: Cell<bool>,
    dialog: RefCell<Option<adw::AlertDialog>>,
    chooser: RefCell<Option<gio::Cancellable>>,
}

impl Controls {
    pub fn new(window: &adw::PreferencesWindow, service: Option<Arc<Service>>) -> Rc<Self> {
        let page = adw::PreferencesPage::builder()
            .title("Diagnostics")
            .icon_name("dialog-information-symbolic")
            .build();
        let group = adw::PreferencesGroup::builder().title("Local Diagnostic Logs")
            .description("Plaintext operational metadata: stages, outcomes, counts, durations and safe error categories. Contents, names, keywords, tags, clipboard text, identities, paths and keys are excluded. Logs stay local and are excluded from library sync and backups. System-log copies follow desktop retention.").build();
        let status = adw::ActionRow::builder()
            .title("Log Storage")
            .subtitle("Retain 14 days, at most 64 files and 24 MiB; roll at 1 MiB or 24 hours.")
            .build();
        group.add(&status);
        let export = gtk::Button::with_label("Export Logs…");
        let delete = gtk::Button::with_label("Delete Logs…");
        for (title, subtitle, button) in [
            (
                "Export Logs",
                "Review and save one validated plaintext JSONL file.",
                &export,
            ),
            (
                "Delete Logs",
                "Remove retained local logs. New operations can create new logs.",
                &delete,
            ),
        ] {
            let row = adw::ActionRow::builder()
                .title(title)
                .subtitle(subtitle)
                .build();
            button.set_valign(gtk::Align::Center);
            row.add_suffix(button);
            row.set_activatable_widget(Some(button));
            group.add(&row);
        }
        page.add(&group);
        let this = Rc::new(Self {
            page,
            window: window.downgrade(),
            service,
            status,
            export,
            delete,
            busy: Cell::new(false),
            quitting: Cell::new(false),
            dialog: RefCell::new(None),
            chooser: RefCell::new(None),
        });
        let weak = Rc::downgrade(&this);
        this.export.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.export_logs();
            }
        });
        let weak = Rc::downgrade(&this);
        this.delete.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.delete_logs();
            }
        });
        this.sensitive();
        this
    }
    fn sensitive(&self) {
        let enabled = self.service.is_some() && !self.busy.get() && !self.quitting.get();
        self.export.set_sensitive(enabled);
        self.delete.set_sensitive(enabled);
        if self.service.is_none() {
            self.status
                .set_subtitle("Diagnostic storage is unavailable in this desktop process.");
        }
    }
    fn begin(&self) -> bool {
        if self.quitting.get() || self.service.is_none() || self.busy.replace(true) {
            return false;
        }
        self.sensitive();
        true
    }
    fn done(&self) {
        self.busy.set(false);
        self.sensitive();
    }
    pub fn can_quit(&self) -> bool {
        !self.busy.get()
    }
    pub fn prepare_quit(&self) -> bool {
        self.quitting.set(true);
        if let Some(dialog) = self.dialog.borrow_mut().take() {
            dialog.close();
        }
        if let Some(chooser) = self.chooser.borrow_mut().take() {
            chooser.cancel();
        }
        self.sensitive();
        self.can_quit()
    }
    pub fn cancel_quit(&self) {
        self.quitting.set(false);
        self.sensitive();
    }
    pub fn refresh(self: &Rc<Self>) {
        if !self.begin() {
            return;
        }
        let service = self.service.clone().unwrap();
        let this = self.clone();
        glib::spawn_future_local(async move {
            match gio::spawn_blocking(move || service.summary())
                .await
                .unwrap_or(Err(LogError::Stopped))
            {
                Ok(summary) => this.status.set_subtitle(&format!(
                    "{} files · {:.1} MiB · {} events dropped when the queue was full",
                    summary.files,
                    summary.bytes as f64 / 1048576.0,
                    summary.dropped
                )),
                Err(error) => this.status.set_subtitle(error.message()),
            }
            this.done();
        });
    }
    fn export_logs(self: &Rc<Self>) {
        if !self.begin() {
            return;
        }
        let Some(window) = self.window.upgrade() else {
            self.done();
            return;
        };
        let this = self.clone();
        glib::spawn_future_local(async move {
            let warning = adw::AlertDialog::builder().heading("Export Plaintext Diagnostic Logs?")
                .body("The file contains operational metadata about Snippets, including vault and account operations. Review it before sharing. Snippet text, names, keywords, clipboard contents, identities, paths and keys are excluded.").build();
            warning.add_responses(&[("cancel", "Cancel"), ("export", "Choose Destination…")]);
            warning.set_default_response(Some("cancel"));
            warning.set_close_response("cancel");
            *this.dialog.borrow_mut() = Some(warning.clone());
            let response = warning.choose_future(Some(&window)).await;
            this.dialog.borrow_mut().take();
            if response != "export" || this.quitting.get() {
                this.done();
                return;
            }
            let chooser = gtk::FileDialog::builder()
                .title("Export Diagnostic Logs")
                .initial_name(format!(
                    "Snippets-linux-diagnostics-{}.jsonl",
                    chrono::Utc::now().format("%Y-%m-%d")
                ))
                .build();
            let cancel = gio::Cancellable::new();
            *this.chooser.borrow_mut() = Some(cancel.clone());
            let parent = window.clone();
            let result = gio::GioFuture::new(&chooser, move |chooser, _, send| {
                chooser.save(Some(&parent), Some(&cancel), move |result| {
                    send.resolve(result)
                });
            })
            .await;
            this.chooser.borrow_mut().take();
            if this.quitting.get() {
                this.done();
                return;
            }
            let Ok(file) = result else {
                this.done();
                return;
            };
            let Some(path) = file.path() else {
                this.status.set_subtitle(LogError::Destination.message());
                this.done();
                return;
            };
            #[cfg(test)]
            live_tests::assert_selection(&path);
            let service = this.service.clone().unwrap();
            this.status
                .set_subtitle("Validating and exporting retained logs…");
            match gio::spawn_blocking(move || service.export(path))
                .await
                .unwrap_or(Err(LogError::Stopped))
            {
                Ok(exported) => this.status.set_subtitle(&format!(
                    "Exported {} records ({} bytes); skipped {} torn final lines.",
                    exported.records, exported.bytes, exported.skipped
                )),
                Err(error) => this.status.set_subtitle(error.message()),
            }
            this.done();
        });
    }
    fn delete_logs(self: &Rc<Self>) {
        if !self.begin() {
            return;
        }
        let Some(window) = self.window.upgrade() else {
            self.done();
            return;
        };
        let this = self.clone();
        glib::spawn_future_local(async move {
            let dialog = adw::AlertDialog::builder().heading("Delete Retained Diagnostic Logs?")
                .body("Remove app-owned diagnostic logs. System-log copies follow desktop retention. Snippets continues recording new operations; library data and encrypted recovery history remain intact.").build();
            dialog.add_responses(&[("cancel", "Cancel"), ("delete", "Delete Logs")]);
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            *this.dialog.borrow_mut() = Some(dialog.clone());
            let response = dialog.choose_future(Some(&window)).await;
            this.dialog.borrow_mut().take();
            if response != "delete" || this.quitting.get() {
                this.done();
                return;
            }
            let service = this.service.clone().unwrap();
            this.status.set_subtitle("Deleting retained logs…");
            match gio::spawn_blocking(move || service.delete())
                .await
                .unwrap_or(Err(LogError::Stopped))
            {
                Ok(summary) => this.status.set_subtitle(&format!(
                    "Deleted {} log files ({} bytes).",
                    summary.files, summary.bytes
                )),
                Err(error) => this.status.set_subtitle(error.message()),
            }
            this.done();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; isolated logs, no global sink or OS-log mirror"]
    fn native_diagnostic_controls_cancel_before_delete_export_and_quit() {
        adw::init().expect("graphical display");
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("library");
        let _library = Library::prepare(root.clone()).unwrap();
        let service = Service::start(root, false).unwrap();
        use crate::diagnostics::Sink;
        service.record(crate::diagnostics::Event::Lifecycle {
            state: crate::diagnostics::Lifecycle::Started,
        });
        service.flush().unwrap();
        let window = adw::PreferencesWindow::builder()
            .search_enabled(true)
            .build();
        let controls = Controls::new(&window, Some(service.clone()));
        window.add(&controls.page);
        window.present();
        controls.refresh();
        settle_until(|| controls.can_quit());
        assert!(controls.status.subtitle().unwrap().contains("1 files"));
        controls.delete_logs();
        settle_until(|| controls.dialog.borrow().is_some());
        assert!(!controls.prepare_quit());
        settle_until(|| controls.can_quit());
        assert_eq!(service.summary().unwrap().files, 1);
        controls.cancel_quit();
        controls.export_logs();
        settle_until(|| controls.dialog.borrow().is_some());
        assert!(!controls.prepare_quit());
        settle_until(|| controls.can_quit());
        assert_eq!(service.summary().unwrap().files, 1);
        assert!(controls.chooser.borrow().is_none());
        window.destroy();
        service.stop();
        settle_until(|| service.finished());
    }
    fn settle_until(done: impl Fn() -> bool) {
        let start = std::time::Instant::now();
        while !done() {
            assert!(start.elapsed() < Duration::from_secs(4));
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

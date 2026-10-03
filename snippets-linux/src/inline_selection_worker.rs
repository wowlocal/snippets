//! Popup ownership, deliberate selection and exact passthrough to the native owner.
use super::*;
use crate::inline_expansion::suggestions::{Choice, Command, Observation, Suggestions};
use std::collections::BTreeSet;
pub(super) struct Popup {
    model: Suggestions,
    choice: Option<Choice>,
    shown: bool,
    redraw: bool,
    driven: bool,
    consumed: BTreeSet<u32>,
    pending: Option<Plan>,
    repeat: Option<(u32, Command, Context, Duration)>,
    rate: u32,
    delay: Duration,
}
impl Default for Popup {
    fn default() -> Self {
        Self {
            model: Suggestions::default(),
            choice: None,
            shown: false,
            redraw: false,
            driven: false,
            consumed: BTreeSet::new(),
            pending: None,
            repeat: None,
            rate: 0,
            delay: Duration::from_millis(400),
        }
    }
}
impl Popup {
    pub fn active(&self) -> bool {
        self.shown
    }
    pub fn clear(
        &mut self,
        connection: &wayland::Connection,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        self.model.reset();
        self.choice = None;
        self.pending = None;
        self.repeat = None;
        self.consumed.clear();
        self.driven = false;
        if self.shown {
            connection.hide_popup(guard)?;
            self.shown = false;
        }
        Ok(())
    }
    pub fn observe(
        &mut self,
        frame: Frame,
        ordinary: &[Snippet],
        ranking: &crate::usage::Snapshot,
    ) {
        let old = self.choice.as_ref().map(Choice::selected_id);
        match self.model.observe(frame, ordinary, ranking) {
            Observation::Hidden => {
                self.choice = None;
                self.repeat = None;
                self.driven = false;
            }
            Observation::Automatic(plan) => {
                self.choice = None;
                self.repeat = None;
                self.pending = Some(plan);
            }
            Observation::Choices(mut choice) => {
                if self.driven
                    && let Some(id) = old
                {
                    choice.select_id(id);
                    self.driven = choice.selected_id() == id;
                }
                if self
                    .repeat
                    .as_ref()
                    .is_some_and(|r| r.2 != choice.context())
                {
                    self.repeat = None;
                }
                self.choice = Some(choice);
                self.redraw = true;
            }
        }
    }
    fn paint(
        &mut self,
        connection: &wayland::Connection,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        if self.redraw
            && let Some(choice) = &self.choice
            && connection.popup(choice, guard)?
        {
            self.shown = true;
            self.redraw = false;
        }
        Ok(())
    }
    pub fn process(
        &mut self,
        library: &Library,
        current: &Frame,
        connection: &wayland::Connection,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<Option<Plan>> {
        self.paint(connection, guard)?;
        while let Some(key) = connection.key() {
            guard()?;
            if key.kind == 2 {
                let (rate, delay) = key.repeat();
                self.rate = rate.min(200);
                self.delay = Duration::from_millis(u64::from(delay.min(10000)));
                if self.rate == 0 {
                    self.repeat = None;
                }
                continue;
            }
            if key.kind > 1 || key.state > 1 {
                return Err(STOPPED);
            }
            if key.kind == 0 && key.state == 0 {
                let consumed = self.consumed.remove(&key.key);
                if self.repeat.as_ref().is_some_and(|r| r.0 == key.key) {
                    self.repeat = None;
                }
                connection.route(&key, consumed, guard)?;
                continue;
            }
            let command = (key.kind == 0
                && key.state == 1
                && self.shown
                && self
                    .choice
                    .as_ref()
                    .is_some_and(|choice| choice.context() == key.context()))
            .then(|| crate::inline_expansion::suggestions::command(key.symbol, key.modifiers))
            .flatten();
            connection.route(&key, command.is_some(), guard)?;
            if let Some(command) = command {
                self.consumed.insert(key.key);
                match command {
                    Command::Next | Command::Previous => {
                        let choice = self.choice.as_mut().ok_or(STOPPED)?;
                        choice.move_selection(command == Command::Next);
                        self.driven = true;
                        self.redraw = true;
                        if self.rate > 0 {
                            self.repeat = Some((
                                key.key,
                                command,
                                choice.context(),
                                crate::clock::uptime().ok_or(STOPPED)? + self.delay,
                            ));
                        }
                    }
                    Command::Accept => {
                        let ordinary = {
                            let _lock = library.try_lock()?;
                            library.read_locked()?.0
                        };
                        self.pending = Some(
                            self.choice
                                .take()
                                .ok_or(STOPPED)?
                                .choose(current, &ordinary)?,
                        );
                        self.repeat = None;
                        self.model.reset();
                    }
                    Command::Dismiss => {
                        self.choice = None;
                        self.repeat = None;
                        self.model.dismiss();
                    }
                }
            }
        }
        if let Some((_, command, context, due)) = self.repeat
            && self.rate > 0
            && self.choice.as_ref().is_some_and(|c| c.context() == context)
            && let Some(now) = crate::clock::uptime()
            && now >= due
        {
            self.choice
                .as_mut()
                .ok_or(STOPPED)?
                .move_selection(command == Command::Next);
            self.redraw = true;
            if let Some(repeat) = self.repeat.as_mut() {
                repeat.3 = now + Duration::from_millis(1000 / u64::from(self.rate.max(1)));
            }
        }
        self.paint(connection, guard)?;
        if self.choice.is_none() && self.shown {
            connection.hide_popup(guard)?;
            self.shown = false;
            self.consumed.clear();
        }
        Ok(self.pending.take())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inline_expansion::wayland::protocol_tests::{
        connect, observe, popup_tests::PopupPeer, words,
    };
    fn baseline(current: &Frame) -> Frame {
        let mut frame = current.copy();
        frame.context.serial = 0;
        frame.text = Some(Zeroizing::new("Public ".into()));
        frame.cursor = 7;
        frame.anchor = 7;
        frame
    }
    #[test]
    fn native_navigation_accepts_fresh_selected_metadata_and_returns_existing_delivery_plan() {
        let temporary = tempfile::tempdir().unwrap();
        let mut library = Library::open(temporary.path().into()).unwrap();
        for keyword in ["calendar", "cafeteria"] {
            let mut snippet = Snippet::new(format!("Public {keyword}"), "Public fictional result");
            snippet.keyword = keyword.into();
            library.save(snippet, None).unwrap();
        }
        let ordinary = library.read().unwrap().0;
        let (peer, fd) = PopupPeer::new();
        let connection = connect(fd, &|| Ok(())).unwrap();
        let current = observe(&connection, 1);
        let mut popup = Popup::default();
        popup.observe(
            baseline(&current),
            &ordinary,
            &crate::usage::Snapshot::default(),
        );
        popup.observe(
            current.copy(),
            &ordinary,
            &crate::usage::Snapshot::default(),
        );
        let first = popup.choice.as_ref().unwrap().selected_id();
        assert!(
            popup
                .process(&library, &current, &connection, &|| Ok(()))
                .unwrap()
                .is_none()
        );
        assert!(popup.active());
        peer.send(
            true,
            vec![(1, words(&[1, 10, 108, 1])), (1, words(&[1, 11, 108, 0]))],
        );
        connection.poll(25, &|| Ok(())).unwrap();
        assert!(
            popup
                .process(&library, &current, &connection, &|| Ok(()))
                .unwrap()
                .is_none()
        );
        let selected = popup.choice.as_ref().unwrap().selected_id();
        assert_ne!(first, selected);
        peer.send(
            true,
            vec![(1, words(&[1, 12, 28, 1])), (1, words(&[1, 13, 28, 0]))],
        );
        connection.poll(25, &|| Ok(())).unwrap();
        let plan = popup
            .process(&library, &current, &connection, &|| Ok(()))
            .unwrap()
            .unwrap();
        assert!(!popup.active());
        assert_eq!(plan.snippet.id, selected);
        assert_eq!(
            plan.selected_query.as_deref().map(|s| s.as_str()),
            Some("ca")
        );
        assert!(plan.prepare("").is_ok());
        drop(connection);
    }
    #[test]
    fn native_accept_refuses_a_changed_saved_body_and_escape_releases_the_grab() {
        for escape in [false, true] {
            let temporary = tempfile::tempdir().unwrap();
            let mut library = Library::open(temporary.path().into()).unwrap();
            let mut snippet = Snippet::new("Public cafeteria", "Public fictional body");
            snippet.keyword = "cafeteria".into();
            library.save(snippet.clone(), None).unwrap();
            let ordinary = library.read().unwrap().0;
            let (peer, fd) = PopupPeer::new();
            let connection = connect(fd, &|| Ok(())).unwrap();
            let current = observe(&connection, 1);
            let mut popup = Popup::default();
            popup.observe(
                baseline(&current),
                &ordinary,
                &crate::usage::Snapshot::default(),
            );
            popup.observe(
                current.copy(),
                &ordinary,
                &crate::usage::Snapshot::default(),
            );
            popup
                .process(&library, &current, &connection, &|| Ok(()))
                .unwrap();
            if !escape {
                snippet.content = "Edited public body".into();
                library.save(snippet, Some(&ordinary[0])).unwrap();
            }
            let code = if escape { 1 } else { 28 };
            peer.send(
                true,
                vec![(1, words(&[1, 10, code, 1])), (1, words(&[1, 11, code, 0]))],
            );
            connection.poll(25, &|| Ok(())).unwrap();
            let result = popup.process(&library, &current, &connection, &|| Ok(()));
            if escape {
                assert!(result.unwrap().is_none());
                assert!(!popup.active());
                assert!(popup.choice.is_none());
            } else {
                assert!(result.is_err());
                popup.clear(&connection, &|| Ok(())).unwrap();
                assert!(!popup.active());
            }
            drop(connection);
        }
    }
}

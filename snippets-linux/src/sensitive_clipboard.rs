//! Bounded native text input for an explicit protected Paste or {clipboard}.
//! GIO futures cancel their native operation when dropped. No clipboard writes.
use crate::model::{self, Error, Result};
use gtk::{glib, prelude::*};
use std::time::{Duration, Instant};
use std::{
    future::{Future, poll_fn},
    task::Poll,
};
use zeroize::Zeroizing;
const UNREADABLE: Error =
    Error("Clipboard text could not be read safely within its size and time limits.");
#[derive(Clone, Copy)]
struct Deadline {
    boot: Duration,
    wall: Instant,
}
impl Deadline {
    fn new() -> Result<Self> {
        Ok(Self {
            boot: crate::clock::uptime().ok_or(UNREADABLE)?,
            wall: Instant::now(),
        })
    }
    fn validate(self) -> Result<()> {
        self.validate_at(crate::clock::uptime(), Instant::now())
    }
    fn validate_at(self, boot: Option<Duration>, wall: Instant) -> Result<()> {
        let boot = boot.ok_or(UNREADABLE)?;
        if boot
            .checked_sub(self.boot)
            .is_none_or(|elapsed| elapsed >= Duration::from_secs(2))
            || wall
                .checked_duration_since(self.wall)
                .is_none_or(|elapsed| elapsed >= Duration::from_secs(2))
        {
            return Err(UNREADABLE);
        }
        Ok(())
    }
}
fn admitted(validate: &dyn Fn() -> Result<()>, deadline: Deadline) -> Result<()> {
    deadline.validate()?;
    validate()
}
async fn wait<T>(
    operation: impl Future<Output = std::result::Result<T, glib::Error>>,
    validate: &dyn Fn() -> Result<()>,
    deadline: Deadline,
) -> Result<T> {
    let mut operation = std::pin::pin!(operation);
    loop {
        admitted(validate, deadline)?;
        let mut tick = std::pin::pin!(glib::timeout_future(Duration::from_millis(30)));
        let outcome = poll_fn(|context| {
            if let Poll::Ready(result) = operation.as_mut().poll(context) {
                Poll::Ready(Some(result))
            } else if tick.as_mut().poll(context).is_ready() {
                Poll::Ready(None)
            } else {
                Poll::Pending
            }
        })
        .await;
        if let Some(outcome) = outcome {
            admitted(validate, deadline)?;
            return outcome.map_err(|_| UNREADABLE);
        }
    }
}
async fn read_stream(
    stream: &gtk::gio::InputStream,
    validate: &dyn Fn() -> Result<()>,
    deadline: Deadline,
) -> Result<Zeroizing<String>> {
    // Allocate once so growth cannot abandon an unwiped Rust-owned prefix.
    let mut bytes = Zeroizing::new(Vec::with_capacity(model::MAX_BODY_BYTES + 1));
    loop {
        let remaining = model::MAX_BODY_BYTES + 1 - bytes.len();
        let chunk = wait(
            stream.read_bytes_future(remaining.min(8192), glib::Priority::DEFAULT),
            validate,
            deadline,
        )
        .await?;
        if chunk.is_empty() {
            break;
        }
        bytes.extend_from_slice(&chunk);
        if bytes.len() > model::MAX_BODY_BYTES {
            return Err(UNREADABLE);
        }
    }
    admitted(validate, deadline)?;
    if bytes.contains(&0) {
        return Err(UNREADABLE);
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| UNREADABLE)?;
    Ok(Zeroizing::new(text.to_owned()))
}
pub(crate) async fn read(
    clipboard: &gtk::gdk::Clipboard,
    validate: impl Fn() -> Result<()>,
) -> Result<Zeroizing<String>> {
    let deadline = Deadline::new()?;
    let (stream, mime) = wait(
        clipboard.read_future(
            &["text/plain;charset=utf-8", "text/plain"],
            glib::Priority::DEFAULT,
        ),
        &validate,
        deadline,
    )
    .await?;
    if !matches!(mime.as_str(), "text/plain;charset=utf-8" | "text/plain") {
        return Err(UNREADABLE);
    }
    read_stream(&stream, &validate, deadline).await
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::{SessionState, SessionWitness};
    use crate::secure_insertion::Authorization;
    use std::{cell::Cell, rc::Rc};
    fn authorization() -> Authorization {
        Authorization::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap()
    }
    #[test]
    fn sensitive_clipboard_deadline_includes_suspend_missing_and_backwards_clocks() {
        let deadline = Deadline::new().unwrap();
        assert!(
            deadline
                .validate_at(Some(deadline.boot), deadline.wall)
                .is_ok()
        );
        assert!(deadline.validate_at(None, deadline.wall).is_err());
        assert!(
            deadline
                .validate_at(Some(deadline.boot - Duration::from_nanos(1)), deadline.wall)
                .is_err()
        );
        assert!(
            deadline
                .validate_at(Some(deadline.boot), deadline.wall - Duration::from_nanos(1))
                .is_err()
        );
        assert!(
            deadline
                .validate_at(Some(deadline.boot + Duration::from_secs(2)), deadline.wall)
                .is_err()
        );
        assert!(
            deadline
                .validate_at(Some(deadline.boot), deadline.wall + Duration::from_secs(2))
                .is_err()
        );
    }
    #[test]
    fn sensitive_clipboard_revocation_after_ready_or_mid_stream_returns_no_prefix() {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| {
                let permitted = Cell::new(true);
                let result = context.block_on(wait(
                    async {
                        permitted.set(false);
                        Ok(())
                    },
                    &|| {
                        if permitted.get() {
                            Ok(())
                        } else {
                            Err(UNREADABLE)
                        }
                    },
                    Deadline::new().unwrap(),
                ));
                assert!(result.is_err());
                let calls = Cell::new(0);
                let stream =
                    gtk::gio::MemoryInputStream::from_bytes(&glib::Bytes::from_owned(vec![
                        b'X';
                        20000
                    ]));
                let result = context.block_on(read_stream(
                    stream.upcast_ref(),
                    &|| {
                        calls.set(calls.get() + 1);
                        if calls.get() >= 3 {
                            Err(UNREADABLE)
                        } else {
                            Ok(())
                        }
                    },
                    Deadline::new().unwrap(),
                ));
                assert!(result.is_err() && calls.get() >= 3);
            })
            .unwrap();
    }
    #[test]
    fn sensitive_clipboard_stream_is_utf8_bounded_and_works_without_a_display() {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| {
                for (bytes, accepted) in [
                    ("Public я中🙂\n\t".as_bytes().to_vec(), true),
                    (vec![], true),
                    (vec![b'X'; model::MAX_BODY_BYTES], true),
                    (vec![b'X'; model::MAX_BODY_BYTES + 1], false),
                    (vec![0xff], false),
                    (b"Public\0fixture".to_vec(), false),
                ] {
                    let stream = gtk::gio::MemoryInputStream::from_bytes(&glib::Bytes::from_owned(
                        bytes.clone(),
                    ));
                    let auth = authorization();
                    let result = context.block_on(read_stream(
                        stream.upcast_ref(),
                        &|| auth.validate(),
                        Deadline::new().unwrap(),
                    ));
                    assert_eq!(result.is_ok(), accepted);
                    if let Ok(text) = result {
                        assert_eq!(text.as_bytes(), bytes);
                    }
                }
            })
            .unwrap();
    }
    struct Stalled(Rc<Cell<bool>>);
    impl Future for Stalled {
        type Output = std::result::Result<(), glib::Error>;
        fn poll(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> Poll<Self::Output> {
            Poll::Pending
        }
    }
    impl Drop for Stalled {
        fn drop(&mut self) {
            self.0.set(true);
        }
    }
    #[test]
    fn sensitive_clipboard_aborting_a_native_task_drops_the_stalled_read() {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| {
                let released = Rc::new(Cell::new(false));
                let future = Stalled(released.clone());
                let task = context.spawn_local(async move {
                    wait(future, &|| Ok(()), Deadline::new().unwrap()).await
                });
                context.iteration(false);
                assert!(!released.get());
                task.abort();
                drop(task);
                assert!(released.get());
            })
            .unwrap();
    }
    #[test]
    fn sensitive_clipboard_revocation_and_deadline_drop_a_stalled_operation() {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| {
                let auth = authorization();
                let cancelled = auth.clone();
                let worker = std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(25));
                    cancelled.cancel();
                });
                let released = Rc::new(Cell::new(false));
                let deadline = Deadline::new().unwrap();
                let wall = std::time::Instant::now();
                assert!(
                    context
                        .block_on(wait(
                            Stalled(released.clone()),
                            &|| auth.validate(),
                            deadline
                        ))
                        .is_err()
                );
                assert!(released.get());
                assert!(wall.elapsed() < Duration::from_secs(1));
                worker.join().unwrap();
                let released = Rc::new(Cell::new(false));
                assert!(
                    context
                        .block_on(wait(
                            Stalled(released.clone()),
                            &|| authorization().validate(),
                            Deadline {
                                boot: crate::clock::uptime().unwrap() - Duration::from_secs(3),
                                wall: Instant::now()
                            }
                        ))
                        .is_err()
                );
                assert!(released.get());
            })
            .unwrap();
    }
}

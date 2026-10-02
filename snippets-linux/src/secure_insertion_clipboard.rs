//! Bounded, cancellable read only for an explicitly requested {clipboard}.
//! GIO futures cancel their native operation when dropped. No clipboard writes.
use super::*;
use crate::{model, secure_insertion::Authorization};
use std::{
    future::{Future, poll_fn},
    task::Poll,
};
const UNREADABLE: Error =
    Error("The clipboard placeholder could not be read safely within its size and time limits.");
fn admitted(authorization: &Authorization, started: Duration) -> Result<()> {
    authorization.validate()?;
    let now = crate::clock::uptime().ok_or(UNREADABLE)?;
    if now < started || now - started >= Duration::from_secs(2) {
        return Err(UNREADABLE);
    }
    Ok(())
}
async fn wait<T>(
    operation: impl Future<Output = std::result::Result<T, glib::Error>>,
    authorization: &Authorization,
    started: Duration,
) -> Result<T> {
    let mut operation = std::pin::pin!(operation);
    loop {
        admitted(authorization, started)?;
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
            admitted(authorization, started)?;
            return outcome.map_err(|_| UNREADABLE);
        }
    }
}
async fn read_stream(
    stream: &gtk::gio::InputStream,
    authorization: &Authorization,
    started: Duration,
) -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::new());
    loop {
        let remaining = model::MAX_BODY_BYTES + 1 - bytes.len();
        let chunk = wait(
            stream.read_bytes_future(remaining.min(8192), glib::Priority::DEFAULT),
            authorization,
            started,
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
    let text = std::str::from_utf8(&bytes).map_err(|_| UNREADABLE)?;
    Ok(Zeroizing::new(text.to_owned()))
}
pub(super) async fn read(
    clipboard: &gtk::gdk::Clipboard,
    authorization: &Authorization,
) -> Result<Zeroizing<String>> {
    let started = crate::clock::uptime().ok_or(UNREADABLE)?;
    let (stream, mime) = wait(
        clipboard.read_future(
            &["text/plain;charset=utf-8", "text/plain"],
            glib::Priority::DEFAULT,
        ),
        authorization,
        started,
    )
    .await?;
    if !matches!(mime.as_str(), "text/plain;charset=utf-8" | "text/plain") {
        return Err(UNREADABLE);
    }
    read_stream(&stream, authorization, started).await
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::{SessionState, SessionWitness};
    fn authorization() -> Authorization {
        Authorization::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap()
    }
    #[test]
    fn insertion_clipboard_stream_is_utf8_bounded_and_works_without_a_display() {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| {
                for (bytes, accepted) in [
                    ("Public я中🙂\n\t".as_bytes().to_vec(), true),
                    (vec![], true),
                    (vec![b'X'; model::MAX_BODY_BYTES], true),
                    (vec![b'X'; model::MAX_BODY_BYTES + 1], false),
                    (vec![0xff], false),
                ] {
                    let stream = gtk::gio::MemoryInputStream::from_bytes(&glib::Bytes::from_owned(
                        bytes.clone(),
                    ));
                    let result = context.block_on(read_stream(
                        stream.upcast_ref(),
                        &authorization(),
                        crate::clock::uptime().unwrap(),
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
    fn insertion_clipboard_revocation_and_deadline_drop_a_stalled_operation() {
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
                let started = crate::clock::uptime().unwrap();
                let wall = std::time::Instant::now();
                assert!(
                    context
                        .block_on(wait(Stalled(released.clone()), &auth, started))
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
                            &authorization(),
                            crate::clock::uptime().unwrap() - Duration::from_secs(3)
                        ))
                        .is_err()
                );
                assert!(released.get());
            })
            .unwrap();
    }
}

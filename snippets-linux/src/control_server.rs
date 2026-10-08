//! Bounded native IPC owner. Secrets stay in connection workers through authentication/delivery.
use super::*;
use crate::{
    secure_insertion::Authorization,
    vault::control::{Captured, Preview},
};
use std::{
    fs::{self, File, OpenOptions},
    os::unix::{
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
};

pub(crate) enum Command {
    Prepare,
    Deny,
    Refuse,
    Authenticate {
        password: Zeroizing<String>,
        recovery: bool,
        authorization: Authorization,
    },
    State(bool),
    Expansion(ExpansionSettings),
    Reject(Status),
}
pub(crate) enum Notice {
    Prepared(Preview),
    Finished {
        status: Status,
        created: Option<Uuid>,
    },
}
pub(crate) struct Offer {
    pub header: Header,
    pub caller: String,
    pub lease: Lease,
    pub commands: mpsc::Sender<Command>,
    pub notices: mpsc::Receiver<Notice>,
}
pub(crate) struct Handle {
    pub receiver: mpsc::Receiver<Offer>,
    stop: Arc<AtomicBool>,
    thread: thread::JoinHandle<()>,
}
struct SocketOwner {
    path: PathBuf,
    identity: (u64, u64),
    _lock: File,
}
impl Drop for SocketOwner {
    fn drop(&mut self) {
        if fs::symlink_metadata(&self.path)
            .is_ok_and(|m| m.file_type().is_socket() && (m.dev(), m.ino()) == self.identity)
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}
impl Handle {
    pub(crate) fn start(root: PathBuf) -> Result<Self> {
        let path = endpoint(&root)?;
        let directory = path.parent().ok_or(REFUSED)?;
        match fs::DirBuilder::new().mode(0o700).create(directory) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(_) => return Err(CLOSED),
        }
        peer::private_directory(directory)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path.with_extension("lock"))
            .map_err(|_| REFUSED)?;
        let m = lock.metadata().map_err(|_| REFUSED)?;
        if !m.is_file()
            || m.nlink() != 1
            || m.len() != 0
            || m.uid() != unsafe { libc::geteuid() }
            || m.mode() & 0o077 != 0
        {
            return Err(REFUSED);
        }
        lock.try_lock().map_err(|_| REFUSED)?;
        if let Ok(m) = fs::symlink_metadata(&path) {
            if !m.file_type().is_socket()
                || m.uid() != unsafe { libc::geteuid() }
                || m.mode() & 0o077 != 0
            {
                return Err(REFUSED);
            }
            match connect(&path) {
                Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
                    fs::remove_file(&path).map_err(|_| REFUSED)?
                }
                _ => return Err(REFUSED),
            }
        }
        let listener = UnixListener::bind(&path).map_err(|_| CLOSED)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|_| CLOSED)?;
        let m = fs::symlink_metadata(&path).map_err(|_| CLOSED)?;
        let owner = SocketOwner {
            path,
            identity: (m.dev(), m.ino()),
            _lock: lock,
        };
        listener.set_nonblocking(true).map_err(|_| CLOSED)?;
        // Verify installation before accepting requests. Every connection pins its own image.
        let _image = peer::Image::sibling("snippets-cli")?;
        let (sender, receiver) = mpsc::sync_channel(8);
        let stop = Arc::new(AtomicBool::new(false));
        let ending = stop.clone();
        let thread = thread::Builder::new()
            .name("snippets-control".into())
            .spawn(move || {
                let _owner = owner;
                let mut workers: Vec<thread::JoinHandle<()>> = Vec::new();
                while !ending.load(Ordering::Acquire) {
                    let mut index = 0;
                    while index < workers.len() {
                        if workers[index].is_finished() {
                            let _ = workers.swap_remove(index).join();
                        } else {
                            index += 1;
                        }
                    }
                    match listener.accept() {
                        Ok((stream, _)) if workers.len() < 8 => {
                            let ending = ending.clone();
                            let sender = sender.clone();
                            let root = root.clone();
                            if let Ok(worker) = thread::Builder::new()
                                .name("snippets-control-request".into())
                                .spawn(move || {
                                    let _ = stream.set_nonblocking(true);
                                    let Ok(image) = peer::Image::sibling("snippets-cli") else {
                                        return;
                                    };
                                    let Ok(lease) = Lease::verified(&stream, image, ending, true)
                                    else {
                                        return;
                                    };
                                    let _ = serve(stream, root, lease, &sender);
                                })
                            {
                                workers.push(worker);
                            }
                        }
                        Ok(_) => (),
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(20))
                        }
                        Err(_) => break,
                    }
                }
                ending.store(true, Ordering::Release);
                for worker in workers {
                    let _ = worker.join();
                }
            })
            .map_err(|_| CLOSED)?;
        Ok(Self {
            receiver,
            stop,
            thread,
        })
    }
    pub(crate) fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }
    pub(crate) fn finished(&self) -> bool {
        self.thread.is_finished()
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        self.stop();
    }
}

fn command(receiver: &mpsc::Receiver<Command>, lease: &Lease) -> Result<Command> {
    loop {
        lease.check()?;
        match receiver.recv_timeout(Duration::from_millis(25)) {
            Ok(value) => return Ok(value),
            Err(mpsc::RecvTimeoutError::Timeout) => (),
            Err(_) => return Err(CLOSED),
        }
    }
}
pub(crate) fn serve(
    stream: UnixStream,
    root: PathBuf,
    lease: Lease,
    sender: &mpsc::SyncSender<Offer>,
) -> Result<()> {
    let mut stream = local_io(stream);
    let header: Header = read_header(&mut stream, &|| lease.check())?;
    if header.v != PROTOCOL {
        return write_header(
            &mut stream,
            &Reply::status(header.nonce, Status::Unsupported).header,
            &|| lease.check(),
        );
    }
    if !["status", "reveal", "add-secure"].contains(&header.command.as_str())
        && ExpansionCommand::from_wire(&header.command).is_none()
    {
        return write_header(
            &mut stream,
            &Reply::status(header.nonce, Status::Unsupported).header,
            &|| lease.check(),
        );
    }
    header.validate()?;
    let body = read_body(&mut stream, header.bytes, &|| lease.check())?;
    let (commands, receiver) = mpsc::channel();
    let (notices, updates) = mpsc::channel();
    let offer = Offer {
        header: header.clone(),
        caller: lease.caller(),
        lease: lease.clone(),
        commands,
        notices: updates,
    };
    if sender.try_send(offer).is_err() {
        return write_header(
            &mut stream,
            &Reply::status(header.nonce, Status::Refused).header,
            &|| lease.check(),
        );
    }
    let result = (|| -> Result<()> {
        let (reply, authorization) = match command(&receiver, &lease)? {
            Command::State(unlocked) if header.command == "status" => {
                let library = model::Library::prepare(root).map_err(|_| INVALID)?;
                let _lock = library.try_lock()?;
                let document = crate::vault::read_document_locked(&library.root)?;
                let mut reply = Reply::status(header.nonce, Status::Ok);
                reply.header.secure_count = Some(document.as_ref().map_or(0, |d| d.records.len()));
                reply.header.unlocked = Some(document.is_some() && unlocked);
                (reply, None)
            }
            Command::Expansion(settings)
                if ExpansionCommand::from_wire(&header.command).is_some() =>
            {
                if !settings.valid() {
                    return Err(INVALID);
                }
                let mut reply = Reply::status(header.nonce, Status::Ok);
                reply.body = Zeroizing::new(serde_json::to_vec(&settings).map_err(|_| INVALID)?);
                reply.header.bytes = reply.body.len();
                (reply, None)
            }
            Command::Reject(status) if status != Status::Ok => {
                (Reply::status(header.nonce, status), None)
            }
            Command::Deny => (Reply::status(header.nonce, Status::Denied), None),
            Command::Refuse => (Reply::status(header.nonce, Status::Refused), None),
            Command::Prepare if matches!(header.command.as_str(), "reveal" | "add-secure") => {
                match Captured::capture(root, &header, body, lease.clone()) {
                    Err(status) => (Reply::status(header.nonce, status), None),
                    Ok(captured) => {
                        let _ = notices.send(Notice::Prepared(captured.preview()));
                        match command(&receiver, &lease)? {
                            Command::Authenticate {
                                password,
                                recovery,
                                authorization,
                            } => match captured.complete(password, recovery, &authorization) {
                                Ok(reply) => {
                                    let secret = header.command == "reveal";
                                    (reply, secret.then_some(authorization))
                                }
                                Err(status) => (Reply::status(header.nonce, status), None),
                            },
                            Command::Deny => (Reply::status(header.nonce, Status::Denied), None),
                            _ => (Reply::status(header.nonce, Status::Refused), None),
                        }
                    }
                }
            }
            _ => (Reply::status(header.nonce, Status::Refused), None),
        };
        let guard = || {
            lease.check()?;
            if let Some(auth) = &authorization {
                auth.validate()?;
            }
            if let Some(delivery) = &reply.delivery {
                delivery.validate()?;
            }
            Ok(())
        };
        write_header(&mut stream, &reply.header, &guard)?;
        write_all(&mut stream, &reply.body, &guard)?;
        let _ = notices.send(Notice::Finished {
            status: reply.header.status,
            created: reply.header.created_id,
        });
        Ok(())
    })();
    if result.is_err() {
        let _ = notices.send(Notice::Finished {
            status: Status::Error,
            created: None,
        });
    }
    result
}

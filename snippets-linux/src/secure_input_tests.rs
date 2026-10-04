use super::*;
use std::os::unix::fs::{PermissionsExt, symlink};
#[test]
fn private_sources_preserve_utf8_and_reject_links_public_permissions_invalid_empty_and_large_input()
{
    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("public-source");
    let public = "Public fictional text 🙂\n";
    std::fs::write(&path, public.as_bytes()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        &*Source::File(path.clone()).read(&|| Ok(())).unwrap(),
        public.as_bytes()
    );
    let link = temporary.path().join("public-link");
    symlink(&path, &link).unwrap();
    assert!(Source::File(link).read(&|| Ok(())).is_err());
    let link = temporary.path().join("public-hardlink");
    std::fs::hard_link(&path, &link).unwrap();
    assert!(Source::File(path.clone()).read(&|| Ok(())).is_err());
    std::fs::remove_file(link).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(Source::File(path.clone()).read(&|| Ok(())).is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    for bytes in [vec![], vec![0xff], vec![0], vec![b'a'; MAX_BODY_BYTES + 1]] {
        std::fs::write(&path, bytes).unwrap();
        assert!(Source::File(path.clone()).read(&|| Ok(())).is_err());
    }
    assert!(Source::Descriptor(-1).read(&|| Ok(())).is_err());
    assert!(Source::File(path).read(&|| Err(INPUT)).is_err());
}
#[test]
fn inherited_private_pipe_is_bounded_and_not_closed_by_the_reader() {
    let mut descriptors = [-1; 2];
    assert_eq!(
        unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC) },
        0
    );
    let input = unsafe { OwnedFd::from_raw_fd(descriptors[0]) };
    let flags = unsafe { libc::fcntl(input.as_raw_fd(), libc::F_GETFL) };
    let mut output = File::from(unsafe { OwnedFd::from_raw_fd(descriptors[1]) });
    output.write_all(b"Public fictional pipe").unwrap();
    drop(output);
    assert_eq!(
        &*Source::Descriptor(input.as_raw_fd())
            .read(&|| Ok(()))
            .unwrap(),
        b"Public fictional pipe"
    );
    assert!(unsafe { libc::fcntl(input.as_raw_fd(), libc::F_GETFD) } >= 0);
    assert_eq!(
        unsafe { libc::fcntl(input.as_raw_fd(), libc::F_GETFL) },
        flags
    );
}

#[test]
fn stalled_private_pipe_can_be_cancelled_without_consuming_or_closing_the_caller_descriptor() {
    let mut descriptors = [-1; 2];
    assert_eq!(
        unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC) },
        0
    );
    let input = unsafe { OwnedFd::from_raw_fd(descriptors[0]) };
    let _output = unsafe { OwnedFd::from_raw_fd(descriptors[1]) };
    let flags = unsafe { libc::fcntl(input.as_raw_fd(), libc::F_GETFL) };
    let start = Instant::now();
    assert!(
        Source::Descriptor(input.as_raw_fd())
            .read(&|| if start.elapsed() > Duration::from_millis(75) {
                Err(INPUT)
            } else {
                Ok(())
            })
            .is_err()
    );
    assert!(start.elapsed() < Duration::from_secs(1));
    assert_eq!(
        unsafe { libc::fcntl(input.as_raw_fd(), libc::F_GETFL) },
        flags
    );
}

#[test]
#[ignore = "requires private /dev/ptmx access; never reads the user's controlling terminal"]
fn private_pty_hidden_prompt_preserves_long_utf8_and_restores_echo_after_success_and_cancellation()
{
    for cancel in [false, true] {
        let mut master = -1;
        let mut slave = -1;
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    std::ptr::null(),
                )
            },
            0,
            "isolated PTY"
        );
        let master = File::from(unsafe { OwnedFd::from_raw_fd(master) });
        let mut slave = File::from(unsafe { OwnedFd::from_raw_fd(slave) });
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(
            unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut original) },
            0
        );
        let fd = slave.as_raw_fd();
        let (ready, started) = std::sync::mpsc::channel();
        let public = "Public fictional 🙂".repeat(400);
        let expected = public.clone();
        let writer = std::thread::spawn(move || {
            started.recv_timeout(Duration::from_secs(2)).unwrap();
            if !cancel {
                (&master)
                    .write_all(format!("{public}🙂\x7f\n").as_bytes())
                    .unwrap();
            }
            master
        });
        let sent = std::cell::Cell::new(false);
        let result = prompt(&mut slave, &|| {
            let mut current = unsafe { std::mem::zeroed::<libc::termios>() };
            assert_eq!(unsafe { libc::tcgetattr(fd, &mut current) }, 0);
            assert_eq!(
                current.c_lflag & (libc::ECHO | libc::ECHONL | libc::ICANON),
                0
            );
            if !sent.replace(true) {
                ready.send(()).unwrap();
            }
            if cancel { Err(INPUT) } else { Ok(()) }
        });
        let master = writer.join().unwrap();
        if cancel {
            assert!(result.is_err());
        } else {
            assert_eq!(&*result.unwrap(), expected.as_bytes());
        }
        let mut restored = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(fd, &mut restored) }, 0);
        assert_eq!(restored.c_lflag, original.c_lflag);
        assert_eq!(restored.c_cc, original.c_cc);
        assert!(Source::Descriptor(fd).read(&|| Ok(())).is_err());
        let mut output = [0; 512];
        unsafe {
            libc::fcntl(master.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK);
        }
        let n = unsafe { libc::read(master.as_raw_fd(), output.as_mut_ptr().cast(), output.len()) };
        assert!(n > 0);
        let output = std::str::from_utf8(&output[..n as usize]).unwrap();
        assert!(output.contains("Secure content (one line): "));
        assert!(!output.contains("Public fictional"));
    }
}

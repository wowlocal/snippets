#![cfg(feature = "local-auth")]
use std::{
    io::Write,
    process::{Command, Stdio},
};
#[test]
fn installed_pam_helper_rejects_invalid_frames_without_authenticating_any_real_account() {
    for mode in 0..4 {
        // An impossible owner UID makes even a framing regression safe: the C
        // adapter refuses identity before starting the system's PAM policy.
        let wrong_uid = if unsafe { libc::geteuid() } == u32::MAX {
            0
        } else {
            u32::MAX
        };
        let mut bytes = wrong_uid.to_be_bytes().to_vec();
        let length: u32 = match mode {
            0 => 0,
            1 => 4097,
            _ => 3,
        };
        bytes.extend_from_slice(&length.to_be_bytes());
        if mode >= 2 {
            bytes.extend_from_slice(&[1, 0, 2]);
        }
        let mut command = Command::new(env!("CARGO_BIN_EXE_snippets-owner-auth"));
        if mode == 3 {
            command.arg("--unknown");
        }
        let mut child = command
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // A rejected-arguments child may close stdin before the write finishes.
        let _ = child.stdin.take().unwrap().write_all(&bytes);
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success() && output.stdout == [1] && output.stderr.is_empty());
    }
}

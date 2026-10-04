//! Native QR encoding. Owned module buffers are erased on drop; the encoder's
//! internal allocations and rendered compositor surfaces are outside that promise.
use std::{ptr::NonNull, sync::Mutex};
use zeroize::{Zeroize, Zeroizing};

const MAX_WIDTH: usize = 177;
const MAX_PAYLOAD: usize = 2331; // Version 40, byte mode, medium correction.
static ENCODER: Mutex<()> = Mutex::new(());
#[repr(C)]
struct Raw {
    version: libc::c_int,
    width: libc::c_int,
    data: *mut u8,
}
unsafe extern "C" {
    fn QRcode_encodeData(
        size: libc::c_int,
        data: *const u8,
        version: libc::c_int,
        level: libc::c_int,
    ) -> *mut Raw;
    fn QRcode_free(code: *mut Raw);
}
struct Encoded(NonNull<Raw>);
impl Drop for Encoded {
    fn drop(&mut self) {
        // The allocation is owned by this result until QRcode_free. Validate its
        // documented width before constructing a mutable slice.
        unsafe {
            let raw = self.0.as_ref();
            if (21..=MAX_WIDTH as i32).contains(&raw.width) && !raw.data.is_null() {
                std::slice::from_raw_parts_mut(raw.data, raw.width as usize * raw.width as usize)
                    .zeroize();
            }
            QRcode_free(self.0.as_ptr());
        }
    }
}
pub(crate) struct Matrix {
    width: usize,
    modules: Zeroizing<Vec<u8>>,
}
impl Matrix {
    pub(crate) fn new(payload: &[u8]) -> Result<Self, ()> {
        if payload.is_empty() || payload.len() > MAX_PAYLOAD {
            return Err(());
        }
        let _guard = ENCODER.lock().map_err(|_| ())?;
        // QR_ECLEVEL_M = 1; version 0 chooses the smallest fitting symbol.
        let code = Encoded(
            NonNull::new(unsafe {
                QRcode_encodeData(payload.len() as i32, payload.as_ptr(), 0, 1)
            })
            .ok_or(())?,
        );
        let raw = unsafe { code.0.as_ref() };
        if !(1..=40).contains(&raw.version)
            || raw.width != 17 + 4 * raw.version
            || raw.data.is_null()
        {
            return Err(());
        }
        let width = raw.width as usize;
        let bytes = unsafe { std::slice::from_raw_parts(raw.data, width * width) };
        Ok(Self {
            width,
            modules: Zeroizing::new(bytes.iter().map(|b| b & 1).collect()),
        })
    }
    pub(crate) fn width(&self) -> usize {
        self.width
    }
    pub(crate) fn dark(&self, x: usize, y: usize) -> bool {
        self.modules[y * self.width + x] != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Write,
        process::{Command, Stdio},
    };

    #[test]
    #[ignore = "requires the independent zbarimg decoder; uses only public fixture data"]
    fn independent_reader_recovers_exact_public_payload() {
        // The fixture contains no account, key or application data. Only this
        // test rasterizes a matrix to disk; production rendering never does.
        let payload = b"{\"fixture\":\"Snippets portable recovery QR\",\"purpose\":\"public decoder check\",\"version\":1}";
        assert_decodes(payload);
        let draft = crate::bootstrap::PairingDraft::generate().unwrap();
        let invitation = crate::bootstrap::Invitation::new(
            crate::cloud::ServerURL::parse("https://public.example.test").unwrap(),
            uuid::Uuid::from_u128(1),
            uuid::Uuid::from_u128(2),
            *draft.nonce(),
            *draft.public_key(),
            1700000300,
            1700000000,
        )
        .unwrap();
        let payload = invitation.encode_qr().unwrap();
        assert_decodes(&payload);
    }
    fn assert_decodes(payload: &[u8]) {
        let matrix = Matrix::new(payload).unwrap();
        let scale = 8;
        let pixels = (matrix.width() + 8) * scale;
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(file, "P5\n{pixels} {pixels}\n255\n").unwrap();
        for y in 0..pixels {
            for x in 0..pixels {
                let mx = x / scale;
                let my = y / scale;
                let dark = mx >= 4
                    && my >= 4
                    && mx < matrix.width() + 4
                    && my < matrix.width() + 4
                    && matrix.dark(mx - 4, my - 4);
                file.write_all(&[if dark { 0 } else { 255 }]).unwrap();
            }
        }
        file.flush().unwrap();
        let output = Command::new("zbarimg")
            .args(["--quiet", "--raw", "--nodbus"])
            .arg(file.path())
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .expect("install zbar to run the independent QR decoder test");
        assert!(output.status.success());
        let mut expected = payload.to_vec();
        expected.push(b'\n');
        assert_eq!(output.stdout, expected);
    }
    #[test]
    fn payload_limits_fail_closed() {
        assert!(Matrix::new(&[]).is_err());
        assert!(Matrix::new(&vec![b'x'; MAX_PAYLOAD + 1]).is_err());
        let matrix = Matrix::new(&vec![b'x'; MAX_PAYLOAD]).unwrap();
        assert_eq!(matrix.width(), MAX_WIDTH);
    }
}

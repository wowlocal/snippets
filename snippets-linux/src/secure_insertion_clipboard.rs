//! Only the explicit placeholder path may request native clipboard input.
use crate::{model::Result, secure_insertion::Authorization};
use zeroize::Zeroizing;
pub(super) async fn read(
    clipboard: &gtk::gdk::Clipboard,
    authorization: &Authorization,
) -> Result<Zeroizing<String>> {
    crate::sensitive_clipboard::read(clipboard, || authorization.validate()).await
}

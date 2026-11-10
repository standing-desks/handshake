//! Detect terminal submissions without interpreting their text.

#[derive(Clone, Default)]
pub(crate) struct UserInputDraft {
    pub(crate) pending: bool,
    pub(crate) pasting: bool,
    escape_pending: bool,
    marker: Vec<u8>,
}

impl UserInputDraft {
    pub(crate) fn observe(&mut self, bytes: &[u8]) -> Option<usize> {
        let mut submission = None;
        for (index, &byte) in bytes.iter().enumerate() {
            if byte == 27 {
                self.escape_pending = self.pending;
            }
            self.marker.push(byte);
            if self.marker.len() > 64 {
                self.marker.remove(0);
            }
            if self.marker.ends_with(b"\x1b[200~") {
                self.pasting = true;
            } else if self.marker.ends_with(b"\x1b[201~") {
                self.pasting = false;
            }
            self.pending = self.pasting || !matches!(byte, b'\r' | b'\n' | 3);
            submission = if self.pasting {
                None
            } else if matches!(byte, b'\r' | b'\n') {
                Some(index)
            } else if let Some((length, release)) = keyboard_enter(&self.marker) {
                self.pending = if release { self.escape_pending } else { false };
                if release || length > index + 1 {
                    None
                } else {
                    Some(index + 1 - length)
                }
            } else {
                None
            };
        }
        submission
    }
}

/// Kitty encodes Enter as CSI 13;modifiers:event u. Shift/other modifiers can mean
/// multiline editing, and key releases must never submit a deferred notification.
fn keyboard_enter(bytes: &[u8]) -> Option<(usize, bool)> {
    if !bytes.ends_with(b"u") {
        return None;
    }
    let start = bytes.windows(2).rposition(|part| part == b"\x1b[")?;
    let body = std::str::from_utf8(&bytes[start + 2..bytes.len() - 1]).ok()?;
    let mut fields = body.split(';');
    if fields.next()?.split(':').next()? != "13" {
        return None;
    }
    let mut modifiers = fields.next().unwrap_or("1").split(':');
    let modifier: u16 = modifiers.next()?.parse().ok()?;
    let event: u8 = modifiers.next().unwrap_or("1").parse().ok()?;
    (event == 3 || (modifier.checked_sub(1)?.trailing_zeros() >= 6 && matches!(event, 1 | 2)))
        .then_some((bytes.len() - start, event == 3))
}

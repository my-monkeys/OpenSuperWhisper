import ApplicationServices

/// Whether an Accessibility element is a secure text field — one whose contents are not the
/// app's to read, whatever it would do with them.
///
/// The comparison lives here and nowhere else. Every reader that touches a field asks it —
/// `SourceCapture.focusedText` (what the transcriber is told), `TextAroundCaret.focused` (how the
/// dictation is fitted) and `WatchedField.focused` (what the user corrected) — so a fourth reader
/// either calls it or is conspicuous in review for not doing so.
///
/// They share it because a password box is not ours to read for *any* purpose, not because all
/// three feed a model: only the first does. It guards the read itself, not what is done with the
/// text afterwards — a password box is not read and then discarded.
enum SecureTextFields {

    /// A missing answer is not secure, because this platform advertises security positively.
    ///
    /// macOS marks a password box by *setting* `kAXSecureTextFieldSubrole`; it does not mark a
    /// safe field by leaving the subrole out. A standard `NSTextField` or `NSTextView` reports
    /// its role (`AXTextField`, `AXTextArea`) and no subrole at all, so absence is the ordinary
    /// case rather than a subset. Refusing on absence would stop reading every ordinary field in
    /// TextEdit, Notes and Mail — caret fitting would have nothing to fit to, the correction
    /// watch would stop watching, and field context would do nothing anywhere.
    ///
    /// An empty answer is treated like a missing one, for the same reason.
    static func isSecure(_ subrole: String?) -> Bool {
        subrole == (kAXSecureTextFieldSubrole as String)
    }
}

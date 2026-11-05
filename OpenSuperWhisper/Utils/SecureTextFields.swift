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

    /// A missing answer counts as secure: the read is refused unless the element positively
    /// reports a non-secure subrole.
    ///
    /// The trade-off is deliberate. This is a privacy gate, and one that opens when the answer is
    /// missing is the wrong default for it: "we could not tell" must not mean "read it". The cost
    /// is real and falls on apps that report no subrole — their fields are no longer read, so
    /// field context does nothing there, caret fitting (`TextAroundCaret`) has nothing to fit to,
    /// and the correction watch (`WatchedField`) stops watching. A feature that does not fire is
    /// a better failure than a password box that does.
    ///
    /// An empty subrole is treated like a missing one: an element that answers with nothing has
    /// not told us it is safe either.
    static func isSecure(_ subrole: String?) -> Bool {
        guard let subrole, !subrole.isEmpty else { return true }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }
}

import ApplicationServices

/// Whether an Accessibility element is a secure text field — one whose contents are not the
/// app's to read, whatever it would do with them.
///
/// The comparison lives here and nowhere else. Every reader that touches a field asks it —
/// `SourceCapture.focusedText` (what the transcriber is told), `TextAroundCaret.focused` (how the
/// dictation is fitted), `WatchedField.focused` (what the user corrected) and
/// `FocusUtils.focusedTextMetrics` (how long the field was and where the caret sat, for the
/// diagnostic log) — so a fifth reader either calls it or is conspicuous in review for not doing so.
///
/// They share it because a password box is not ours to read for *any* purpose, not because all
/// of them feed a model: only the first does. It guards the read itself, not what is done with
/// the text afterwards — a password box is not read and then discarded.
enum SecureTextFields {

    /// Whether the answer to `kAXSubroleAttribute` says the field is secure.
    ///
    /// The error is part of the answer, not a detail beside it. macOS marks a password box by
    /// *setting* `kAXSecureTextFieldSubrole`; it does not mark a safe field by leaving the
    /// subrole out. A standard `NSTextField` or `NSTextView` reports its role (`AXTextField`,
    /// `AXTextArea`) and no subrole at all, so absence is the ordinary case rather than a
    /// subset. Refusing on absence would stop reading every ordinary field in TextEdit, Notes
    /// and Mail — caret fitting would have nothing to fit to, the correction watch would stop
    /// watching, and field context would do nothing anywhere.
    ///
    /// Only two errors say the attribute is genuinely absent: `.attributeUnsupported` (this
    /// element has no such attribute) and `.noValue` (it has one, holding nothing). Every other
    /// failure is a question that was not answered — `cannotComplete` is what a request that
    /// timed out returns, `invalidUIElement` what a dead element returns, `apiDisabled` what an
    /// untrusted process gets — and an unanswered question is refused. The cost of guessing
    /// wrong is a password read for a model or written to a log; the cost of refusing wrongly is
    /// that one dictation goes in as it did before field context existed.
    ///
    /// An empty string on a successful read is treated like a missing one, for the same reason.
    static func isSecure(_ subrole: String?, error: AXError) -> Bool {
        // Absence, only when the app said so.
        if error == .attributeUnsupported || error == .noValue { return false }
        // Any other failure leaves the question open, and an open question refuses.
        guard error == .success else { return true }
        // A .success read whose value is not a CFString reads as absent: macOS does not
        // produce that shape for kAXSubroleAttribute, so the predicate does not widen for it.
        return subrole == (kAXSecureTextFieldSubrole as String)
    }
}

import ApplicationServices

/// Whether an Accessibility element is a secure text field — one whose contents are not the
/// app's to read, whatever it would do with them.
///
/// The comparison lives here and nowhere else. The three readers that feed a model —
/// `SourceCapture.focusedText`, `TextAroundCaret.focused` and `WatchedField.focused` — each ask
/// this predicate, so a fourth reader either calls it or is conspicuous in review for not doing
/// so. It guards the read itself, not what is done with the text afterwards: a password box is
/// not read and then discarded.
enum SecureTextFields {

    /// `nil` is not secure. An app that does not report a subrole has not said the field is one,
    /// and refusing every field with no answer would turn this guard into an outage.
    static func isSecure(_ subrole: String?) -> Bool {
        subrole == (kAXSecureTextFieldSubrole as String)
    }
}

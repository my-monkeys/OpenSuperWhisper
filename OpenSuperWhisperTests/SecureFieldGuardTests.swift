import ApplicationServices
import XCTest

@testable import OpenSuperWhisper

/// The one comparison that decides a field is a password box. Every reader that touches a field
/// asks here — only `SourceCapture` feeds a model, but a password box is not read for any purpose
/// — so the guard has a single implementation and a new reader has one thing to call.
final class SecureFieldGuardTests: XCTestCase {

    func testTheSystemSecureSubroleIsRefused() {
        XCTAssertTrue(SecureTextFields.isSecure(kAXSecureTextFieldSubrole as String))
    }

    /// A real non-secure subrole. There is no `kAXTextFieldSubrole`: roles and subroles are
    /// separate namespaces, and an ordinary text field is role `AXTextField` with no subrole at
    /// all — which is why silence is the normal case below, not a refusal.
    func testAnOrdinaryFieldIsNotRefused() {
        XCTAssertFalse(SecureTextFields.isSecure(kAXSearchFieldSubrole as String))
    }

    /// Security is advertised positively on this platform. An ordinary text field reports no
    /// subrole at all, so silence and an empty answer are the normal case, not a refusal.
    func testSilenceIsNotRefused() {
        XCTAssertFalse(SecureTextFields.isSecure(nil))
        XCTAssertFalse(SecureTextFields.isSecure(""))
    }
}

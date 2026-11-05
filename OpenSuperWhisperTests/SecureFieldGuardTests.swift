import ApplicationServices
import XCTest

@testable import OpenSuperWhisper

/// The one comparison that decides a field is a password box. The three readers that feed a
/// model all ask here, so the guard has a single implementation and a new reader has one thing
/// to call.
final class SecureFieldGuardTests: XCTestCase {

    func testTheSystemSecureSubroleIsRefused() {
        XCTAssertTrue(SecureTextFields.isSecure(kAXSecureTextFieldSubrole as String))
    }

    func testAnOrdinaryFieldIsNotRefused() {
        XCTAssertFalse(SecureTextFields.isSecure(kAXTextFieldSubrole as String))
    }

    /// Security is advertised positively on this platform. An ordinary text field reports no
    /// subrole at all, so silence and an empty answer are the normal case, not a refusal.
    func testSilenceIsNotRefused() {
        XCTAssertFalse(SecureTextFields.isSecure(nil))
        XCTAssertFalse(SecureTextFields.isSecure(""))
    }
}

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

    /// An app that does not report a subrole has not said the field is safe, and a gate for a
    /// privacy control opens only on a positive answer. Silence and an empty answer both refuse.
    func testSilenceIsRefused() {
        XCTAssertTrue(SecureTextFields.isSecure(nil))
        XCTAssertTrue(SecureTextFields.isSecure(""))
    }
}

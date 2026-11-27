import ApplicationServices
import XCTest

@testable import OpenSuperWhisper

/// The one comparison that decides a field is a password box. Every reader that touches a field
/// asks here — only `SourceCapture` feeds a model, but a password box is not read for any purpose
/// — so the guard has a single implementation and a new reader has one thing to call.
///
/// The error rows matter as much as the value rows. The read returns a subrole *and* the error it
/// came with, and the failure this suite exists to prevent is a failed read being mistaken for
/// the ordinary no-subrole case.
final class SecureFieldGuardTests: XCTestCase {

    func testTheSystemSecureSubroleIsRefused() {
        XCTAssertTrue(SecureTextFields.isSecure(kAXSecureTextFieldSubrole as String, error: .success))
    }

    /// A real non-secure subrole. There is no `kAXTextFieldSubrole`: roles and subroles are
    /// separate namespaces, and an ordinary text field is role `AXTextField` with no subrole at
    /// all — which is why silence is the normal case below, not a refusal.
    func testAnOrdinaryFieldIsNotRefused() {
        XCTAssertFalse(SecureTextFields.isSecure(kAXSearchFieldSubrole as String, error: .success))
    }

    /// Security is advertised positively on this platform. An ordinary text field reports no
    /// subrole at all, so silence and an empty answer are the normal case, not a refusal.
    func testSilenceIsNotRefused() {
        XCTAssertFalse(SecureTextFields.isSecure(nil, error: .success))
        XCTAssertFalse(SecureTextFields.isSecure("", error: .success))
    }

    /// The two errors that mean the attribute is genuinely absent. Without them the guard would
    /// refuse every ordinary field in every app, which is the other half of the failure: caret
    /// fitting, the correction watch and field context would all stop working.
    func testTheAbsentAttributeErrorsAreNotRefused() {
        for error in [AXError.attributeUnsupported, .noValue] {
            XCTAssertFalse(SecureTextFields.isSecure(nil, error: error), "\(error)")
        }
    }

    /// A timeout is what a request that did not come back returns. It says nothing about the
    /// subrole, so the field is refused: one wrong guess reads a password box, and no local
    /// instrument can catch that happening at runtime.
    func testATimedOutReadIsRefused() {
        XCTAssertTrue(SecureTextFields.isSecure(nil, error: .cannotComplete))
    }

    /// The value does not rescue a failed read: an app that timed out has not answered, whatever
    /// its half-returned subrole happens to look like.
    func testAFailedReadIsRefusedWhateverTheValueLooksLike() {
        XCTAssertTrue(SecureTextFields.isSecure(kAXSearchFieldSubrole as String, error: .cannotComplete))
    }

    /// Every remaining non-success error is an unanswered question too — a dead element, a
    /// disabled API, a call the app did not implement, a notification question, or an answer too
    /// imprecise to use. A sweep rather than one row, so a new error code cannot slip into a
    /// default that reads as "not secure".
    ///
    /// Mutation: return false where the predicate refuses, and every row here reddens — as do
    /// the `cannotComplete` rows above, which refuse for the same reason.
    func testEveryOtherErrorRefuses() {
        let unanswered: [AXError] = [
            .failure, .illegalArgument, .invalidUIElement, .invalidUIElementObserver,
            .actionUnsupported, .notificationUnsupported, .notImplemented,
            .notificationAlreadyRegistered, .notificationNotRegistered, .apiDisabled,
            .parameterizedAttributeUnsupported, .notEnoughPrecision,
        ]
        for error in unanswered {
            XCTAssertTrue(SecureTextFields.isSecure(nil, error: error), "\(error)")
        }
    }
}

import XCTest

@testable import OpenSuperWhisper

/// The submit mouse button dictates and then presses Return (#50). The monitor has to watch
/// two buttons at once and report which one fired, since that is what decides whether the
/// clip submits.
final class SubmitMouseButtonTests: XCTestCase {

    /// Every case maps to a distinct CGEvent button number, or watching two buttons would
    /// collapse them into one entry and the submit button would go unnoticed.
    func testButtonNumbersAreUnique() {
        let numbers = MouseButton.allCases
            .filter { $0 != .none }
            .map(\.buttonNumber)
        XCTAssertEqual(Set(numbers).count, numbers.count)
        XCTAssertFalse(numbers.contains(MouseButton.none.buttonNumber),
                       "the disabled case must not collide with a real button")
    }

    /// The picker offers the same buttons as the record trigger, so both can be configured
    /// from the same set.
    func testEveryRealButtonCanBeChosen() {
        let choices = MouseButton.allCases.filter { $0 != .none }
        XCTAssertFalse(choices.isEmpty)
        for choice in choices {
            XCTAssertEqual(MouseButton(rawValue: choice.rawValue), choice,
                           "\(choice.rawValue) must round-trip through preferences")
        }
    }

    func testDefaultIsDisabled() {
        XCTAssertEqual(MouseButton(rawValue: "none"), MouseButton.none)
        XCTAssertEqual(MouseButton.none.buttonNumber, -1,
                       "disabled must never match a real event")
    }
}

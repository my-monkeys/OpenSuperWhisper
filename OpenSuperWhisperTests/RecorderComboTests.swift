import AppKit
import Carbon.HIToolbox
import XCTest

@testable import OpenSuperWhisper

final class RecorderComboTests: XCTestCase {
    func testRequiresCommandOptionOrControl() {
        XCTAssertTrue(RecorderCombo.isValid(modifiers: [.command], keyCode: kVK_ANSI_A))
        XCTAssertTrue(RecorderCombo.isValid(modifiers: [.option, .shift], keyCode: kVK_ANSI_A))
        XCTAssertTrue(RecorderCombo.isValid(modifiers: [.control], keyCode: kVK_Space))
        XCTAssertFalse(RecorderCombo.isValid(modifiers: [], keyCode: kVK_ANSI_A))
    }

    func testShiftAloneIsRejected() {
        XCTAssertFalse(RecorderCombo.isValid(modifiers: [.shift], keyCode: kVK_ANSI_A))
    }

    func testBareFunctionKeysAllowed() {
        XCTAssertTrue(RecorderCombo.isValid(modifiers: [], keyCode: kVK_F5))
        XCTAssertTrue(RecorderCombo.isValid(modifiers: [.shift], keyCode: kVK_F13))
        XCTAssertFalse(RecorderCombo.isValid(modifiers: [], keyCode: kVK_Escape))
    }
}

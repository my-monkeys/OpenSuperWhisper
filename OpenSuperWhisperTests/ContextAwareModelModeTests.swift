import XCTest
@testable import OpenSuperWhisper

/// The context-aware model mode gates two behaviors independently: whether to
/// auto-switch the model by app at record-start (`autoSwitches`), and whether to
/// prompt for scope when you pick a model in the menu-bar picker (`prompts`).
/// `.ask` does both, `.auto` switches silently, `.off` does neither. This guards
/// that mapping and the raw-value round-trip used to persist the setting.
final class ContextAwareModelModeTests: XCTestCase {

    func testAskAutoSwitchesAndPrompts() {
        XCTAssertTrue(ContextAwareModelMode.ask.autoSwitches)
        XCTAssertTrue(ContextAwareModelMode.ask.prompts)
    }

    func testAutoSwitchesWithoutPrompting() {
        XCTAssertTrue(ContextAwareModelMode.auto.autoSwitches)
        XCTAssertFalse(ContextAwareModelMode.auto.prompts)
    }

    func testOffDoesNeither() {
        XCTAssertFalse(ContextAwareModelMode.off.autoSwitches)
        XCTAssertFalse(ContextAwareModelMode.off.prompts)
    }

    func testRoundTripsThroughRawValue() {
        for mode in ContextAwareModelMode.allCases {
            XCTAssertEqual(ContextAwareModelMode(rawValue: mode.rawValue), mode)
        }
    }
}

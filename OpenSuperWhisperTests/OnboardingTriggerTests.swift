import XCTest
@testable import OpenSuperWhisper

/// Onboarding's Right ⌥ choice has to reach the trigger list the app listens to. It used to
/// land only in the old single-slot key, so a fresh install showed no trigger in Settings.
final class OnboardingTriggerTests: XCTestCase {
    private var savedRegular = ""
    private var savedHold = ""

    override func setUp() {
        savedRegular = AppPreferences.shared.recordingTriggers
        savedHold = AppPreferences.shared.holdRecordingTriggers
        AppPreferences.shared.recordingTriggers = RecordingTriggerSet.empty.json
        AppPreferences.shared.holdRecordingTriggers = RecordingTriggerSet.empty.json
    }

    override func tearDown() {
        AppPreferences.shared.recordingTriggers = savedRegular
        AppPreferences.shared.holdRecordingTriggers = savedHold
    }

    private var regular: [RecordingTrigger] {
        RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers).triggers
    }

    func testChoosingRightOptionAddsItToTheList() {
        AppPreferences.shared.setRightOptionTrigger(true)
        XCTAssertEqual(regular, [.modifier(.rightOption)])
    }

    func testSwitchingBackRemovesIt() {
        AppPreferences.shared.setRightOptionTrigger(true)
        AppPreferences.shared.setRightOptionTrigger(false)
        XCTAssertEqual(regular, [])
    }

    func testChoosingItTwiceKeepsOneRow() {
        AppPreferences.shared.setRightOptionTrigger(true)
        AppPreferences.shared.setRightOptionTrigger(true)
        XCTAssertEqual(regular, [.modifier(.rightOption)])
    }

    func testAlreadyAHoldTriggerStaysThere() {
        // The two lists never share a key.
        var hold = RecordingTriggerSet.empty
        hold.add(.modifier(.rightOption))
        AppPreferences.shared.holdRecordingTriggers = hold.json
        AppPreferences.shared.setRightOptionTrigger(true)
        XCTAssertEqual(regular, [])
    }
}

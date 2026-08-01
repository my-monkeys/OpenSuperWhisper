import AppKit
import XCTest

@testable import OpenSuperWhisper

/// The unified trigger field records whatever the user does: a combination, a lone modifier,
/// or a mouse button. The lone-modifier rule is the delicate one — recording ⌥ when the user
/// was reaching for ⌥⇧K would hand them a trigger that fires constantly.
final class SingleModifierDetectorTests: XCTestCase {

    private let rightOption = ModifierKey.rightOption
    private let leftShift = ModifierKey.leftShift

    func testCleanPressIsRecognised() {
        var detector = SingleModifierDetector()
        XCTAssertNil(detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: [.option]))
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: []),
                       rightOption)
    }

    /// Two modifiers means a combination is being typed, not a lone press.
    func testSecondModifierDisqualifies() {
        var detector = SingleModifierDetector()
        _ = detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: [.option])
        _ = detector.handleFlagsChanged(keyCode: leftShift.keyCode, flags: [.option, .shift])
        XCTAssertNil(detector.handleFlagsChanged(keyCode: leftShift.keyCode, flags: [.option]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: []),
                     "⌥⇧ is the start of a combination, not a single-modifier trigger")
    }

    /// ⌥ then K: the key press has to cancel the pending modifier, or releasing ⌥ afterwards
    /// would record it.
    func testKeyPressDisqualifies() {
        var detector = SingleModifierDetector()
        _ = detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: [.option])
        detector.contaminate()
        XCTAssertNil(detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: []))
    }

    /// After a disqualified press, the next clean one still works.
    func testDetectorRecoversAfterContamination() {
        var detector = SingleModifierDetector()
        _ = detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: [.option])
        detector.contaminate()
        _ = detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: [])

        _ = detector.handleFlagsChanged(keyCode: leftShift.keyCode, flags: [.shift])
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: leftShift.keyCode, flags: []),
                       leftShift)
    }

    func testResetClearsAPendingPress() {
        var detector = SingleModifierDetector()
        _ = detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: [.option])
        detector.reset()
        XCTAssertNil(detector.handleFlagsChanged(keyCode: rightOption.keyCode, flags: []))
    }

    /// Left and right of the same modifier are distinct triggers, so releasing the other side
    /// must not record the pending one.
    func testSidesAreNotInterchangeable() {
        var detector = SingleModifierDetector()
        _ = detector.handleFlagsChanged(keyCode: ModifierKey.leftCommand.keyCode, flags: [.command])
        XCTAssertNil(detector.handleFlagsChanged(keyCode: ModifierKey.rightCommand.keyCode, flags: []))
    }
}

/// Stored preferences resolve to exactly one trigger, and the precedence has to match what
/// ShortcutManager has always done, or an upgrade would silently change someone's trigger.
final class RecordingTriggerResolveTests: XCTestCase {

    func testMouseWinsOverModifierAndCombo() {
        let trigger = RecordingTrigger.resolve(mouseRaw: "middle", modifierRaw: "rightOption", shortcut: nil)
        XCTAssertEqual(trigger, .mouse(.middle))
    }

    func testModifierWinsOverCombo() {
        let trigger = RecordingTrigger.resolve(mouseRaw: "none", modifierRaw: "fn", shortcut: nil)
        XCTAssertEqual(trigger, .modifier(.fn))
    }

    func testNothingStoredIsNoTrigger() {
        XCTAssertEqual(RecordingTrigger.resolve(mouseRaw: "none", modifierRaw: "none", shortcut: nil),
                       .none)
    }

    /// An unknown stored value (downgrade, hand-edited defaults) must not resolve to a trigger
    /// the app can't act on.
    func testUnknownStoredValuesAreIgnored() {
        XCTAssertEqual(RecordingTrigger.resolve(mouseRaw: "button99", modifierRaw: "hyper", shortcut: nil),
                       .none)
    }
}

import AppKit
import KeyboardShortcuts
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

/// Keyboard and mouse triggers coexist: a thumb button at the desk and a shortcut on the move,
/// without a trip through Settings between them (#48).
final class MultipleRecordingTriggersTests: XCTestCase {

    @MainActor
    private func combo() -> KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .option])
    }

    @MainActor
    func testAllConfiguredTriggersAreReturned() {
        let triggers = RecordingTrigger.resolveAll(mouseRaw: "button4",
                                                   modifierRaw: "rightOption",
                                                   shortcut: combo())
        XCTAssertEqual(triggers.count, 3)
        XCTAssertTrue(triggers.contains(.mouse(.button4)))
        XCTAssertTrue(triggers.contains(.modifier(.rightOption)))
    }

    /// The old resolver picked one by precedence, which is what made the modes exclusive.
    /// Keeping it for the single-binding fields means both behaviours have to stay distinct.
    @MainActor
    func testSingleResolverStillPicksOneByPrecedence() {
        let single = RecordingTrigger.resolve(mouseRaw: "button4",
                                              modifierRaw: "rightOption",
                                              shortcut: combo())
        XCTAssertEqual(single, .mouse(.button4))
    }

    @MainActor
    func testNothingConfiguredYieldsNoTriggers() {
        XCTAssertTrue(RecordingTrigger.resolveAll(mouseRaw: "none", modifierRaw: "none",
                                                  shortcut: nil).isEmpty)
    }

    @MainActor
    func testPartialConfigurationReturnsOnlyWhatIsSet() {
        let triggers = RecordingTrigger.resolveAll(mouseRaw: "none",
                                                   modifierRaw: "fn",
                                                   shortcut: nil)
        XCTAssertEqual(triggers, [.modifier(.fn)])
    }

    /// Two triggers of the same kind can't coexist — there is one slot per kind — so recording a
    /// second mouse button has to replace the first rather than accumulate.
    @MainActor
    func testKindsAreDistinctSoSameKindReplaces() {
        XCTAssertEqual(RecordingTrigger.mouse(.button4).kind, RecordingTrigger.mouse(.button5).kind)
        XCTAssertNotEqual(RecordingTrigger.mouse(.button4).kind, RecordingTrigger.modifier(.fn).kind)
        XCTAssertNotEqual(RecordingTrigger.modifier(.fn).kind, RecordingTrigger.keyCombo(combo()).kind)
    }

    /// An unknown stored value must not become a phantom trigger the app can't act on.
    @MainActor
    func testUnknownStoredValuesAreSkipped() {
        let triggers = RecordingTrigger.resolveAll(mouseRaw: "button99",
                                                   modifierRaw: "hyper",
                                                   shortcut: nil)
        XCTAssertTrue(triggers.isEmpty)
    }
}

/// The trigger list holds any number of each kind. The previous shape had one slot per kind —
/// one shortcut, one modifier, one mouse button — so three was the ceiling however the UI was
/// drawn (#48).
final class RecordingTriggerSetTests: XCTestCase {

    @MainActor
    private func combo(_ key: KeyboardShortcuts.Key) -> KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(key, modifiers: [.command, .option])
    }

    @MainActor
    func testHoldsSeveralOfTheSameKind() {
        var set = RecordingTriggerSet.empty
        set.add(.keyCombo(combo(.d)))
        set.add(.keyCombo(combo(.k)))
        set.add(.mouse(.button4))
        set.add(.mouse(.button5))
        set.add(.modifier(.rightOption))
        set.add(.modifier(.fn))

        XCTAssertEqual(set.keyCombos.count, 2)
        XCTAssertEqual(set.mouseButtons, [.button4, .button5])
        XCTAssertEqual(set.modifiers, [.rightOption, .fn])
    }

    /// Recording the same key twice should change nothing, not add a row that fires once.
    @MainActor
    func testDuplicatesAreIgnored() {
        var set = RecordingTriggerSet.empty
        set.add(.mouse(.button4))
        set.add(.mouse(.button4))
        XCTAssertEqual(set.triggers.count, 1)
    }

    func testEmptyTriggerIsNeverStored() {
        var set = RecordingTriggerSet.empty
        set.add(.none)
        XCTAssertTrue(set.triggers.isEmpty)
    }

    @MainActor
    func testRemoveTakesOnlyTheOneAskedFor() {
        var set = RecordingTriggerSet.empty
        set.add(.mouse(.button4))
        set.add(.modifier(.fn))
        set.add(.keyCombo(combo(.d)))

        set.remove(.modifier(.fn))

        XCTAssertEqual(set.triggers, [.mouse(.button4), .keyCombo(combo(.d))])
    }

    @MainActor
    func testRoundTripsThroughJSON() {
        var set = RecordingTriggerSet.empty
        set.add(.keyCombo(combo(.d)))
        set.add(.modifier(.rightCommand))
        set.add(.mouse(.button7))
        XCTAssertEqual(RecordingTriggerSet.load(from: set.json), set)
    }

    func testUnreadableStoredValueYieldsNoTriggers() {
        XCTAssertEqual(RecordingTriggerSet.load(from: "not json"), .empty)
        XCTAssertEqual(RecordingTriggerSet.load(from: ""), .empty)
    }

    /// Upgrading must keep whatever was configured before the list existed.
    @MainActor
    func testMigrationCarriesTheOldSlots() {
        let set = RecordingTriggerSet.migrated(mouseRaw: "button4", modifierRaw: "rightOption",
                                               shortcut: combo(.d))
        XCTAssertEqual(set.triggers.count, 3)
        XCTAssertTrue(set.mouseButtons.contains(.button4))
        XCTAssertTrue(set.modifiers.contains(.rightOption))
        XCTAssertEqual(set.keyCombos.count, 1)
    }

    func testMigrationOfAnUnconfiguredInstallIsEmpty() {
        XCTAssertEqual(RecordingTriggerSet.migrated(mouseRaw: "none", modifierRaw: "none",
                                                    shortcut: nil), .empty)
    }
}

/// A key can only mean one thing. Bound as both a recording trigger and stop-and-submit, the
/// router checks submit first, so the trigger silently stops starting anything — a working
/// binding that looks broken with nothing on screen to explain it.
final class TriggerConflictTests: XCTestCase {

    private func set(modifier: ModifierKey? = nil, mouse: MouseButton? = nil) -> RecordingTriggerSet {
        var set = RecordingTriggerSet.empty
        if let modifier { set.add(.modifier(modifier)) }
        if let mouse { set.add(.mouse(mouse)) }
        return set
    }

    func testDetectsAModifierClaimedByBoth() {
        let clash = set(modifier: .rightCommand).conflicts(modifier: .rightCommand, mouse: .none)
        XCTAssertTrue(clash.modifier)
        XCTAssertFalse(clash.mouse)
    }

    func testDetectsAMouseButtonClaimedByBoth() {
        let clash = set(mouse: .button4).conflicts(modifier: .none, mouse: .button4)
        XCTAssertTrue(clash.mouse)
    }

    func testDifferentKeysDoNotClash() {
        let clash = set(modifier: .rightOption, mouse: .button4)
            .conflicts(modifier: .rightCommand, mouse: .button5)
        XCTAssertFalse(clash.modifier)
        XCTAssertFalse(clash.mouse)
    }

    /// "none" means unbound on both sides and must never register as a collision.
    func testUnboundNeverClashes() {
        XCTAssertFalse(set(modifier: .rightOption).conflicts(modifier: .none, mouse: .none).modifier)
        XCTAssertFalse(RecordingTriggerSet.empty.conflicts(modifier: .none, mouse: .none).mouse)
    }
}

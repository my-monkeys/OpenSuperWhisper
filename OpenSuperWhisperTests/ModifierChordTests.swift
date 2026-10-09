import AppKit
import XCTest
@testable import OpenSuperWhisper

/// ⌘⌥ on its own as a trigger. It must fire only for a clean press, since ⌘⌥ also begins
/// ordinary shortcuts like ⌘⌥I: one key added while it is held turns it into a shortcut.
final class ModifierChordTests: XCTestCase {

    func testOneModifierIsNotAChord() {
        XCTAssertNil(ModifierChord([.command]))
    }

    func testTwoModifiersMakeAChord() {
        let chord = ModifierChord([.command, .option])
        XCTAssertEqual(chord?.symbols, ["⌥", "⌘"])
    }

    func testCapsLockAndFnAreIgnored() {
        XCTAssertEqual(ModifierChord([.command, .option, .capsLock, .function]),
                       ModifierChord([.command, .option]))
    }

    func testStorageRoundTrip() {
        let chord = ModifierChord([.control, .shift])!
        XCTAssertEqual(ModifierChord(storageValue: chord.storageValue), chord)
        XCTAssertNil(ModifierChord(storageValue: ""))
    }

    func testCleanPressFiresOnRelease() {
        var detector = ChordDetector()
        XCTAssertNil(detector.handleFlagsChanged(flags: [.command]))
        XCTAssertNil(detector.handleFlagsChanged(flags: [.command, .option]))
        XCTAssertNil(detector.handleFlagsChanged(flags: [.option]))
        XCTAssertEqual(detector.handleFlagsChanged(flags: []), ModifierChord([.command, .option]))
    }

    func testAKeyPressedMeanwhileMakesItAShortcut() {
        var detector = ChordDetector()
        _ = detector.handleFlagsChanged(flags: [.command, .option])
        detector.contaminate()  // ⌘⌥I
        XCTAssertNil(detector.handleFlagsChanged(flags: []))
    }

    func testTheNextPressStartsClean() {
        var detector = ChordDetector()
        _ = detector.handleFlagsChanged(flags: [.command, .option])
        detector.contaminate()
        _ = detector.handleFlagsChanged(flags: [])
        _ = detector.handleFlagsChanged(flags: [.command, .option])
        XCTAssertEqual(detector.handleFlagsChanged(flags: []), ModifierChord([.command, .option]))
    }

    func testSingleModifierPressIsNotAChord() {
        var detector = ChordDetector()
        _ = detector.handleFlagsChanged(flags: [.option])
        XCTAssertNil(detector.handleFlagsChanged(flags: []))
    }

    func testChordTriggerSurvivesTheTriggerListJSON() {
        var set = RecordingTriggerSet.empty
        set.add(.chord(ModifierChord([.command, .option])!))
        XCTAssertEqual(RecordingTriggerSet.load(from: set.json).chords, [ModifierChord([.command, .option])!])
    }
}

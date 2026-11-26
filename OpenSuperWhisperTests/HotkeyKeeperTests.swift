//
//  HotkeyKeeperTests.swift
//  OpenSuperWhisperTests
//
//  The trigger shortcut could stop answering until the app was relaunched: the shortcut library
//  drops a hot key it fails to put back after a menu closes, and macOS holds back Option
//  shortcuts during secure input. These pin down when the keeper steps in.
//

import Carbon
import XCTest
@testable import OpenSuperWhisper

final class HotkeyKeeperTests: XCTestCase {

    private func action(
        pending: Bool = false, dropped: Bool = false, take: Bool = false,
        paused: Bool = false, armed: Bool = false, lost: Bool = false
    ) -> HotkeyKeeper.Action {
        HotkeyKeeper.action(
            reregisterPending: pending, anyDropped: dropped, takeRunning: take,
            libraryPaused: paused, captureArmed: armed, anyLost: lost)
    }

    func testNothingToDoWhenEveryShortcutIsListening() {
        XCTAssertEqual(action(), .none)
    }

    func testADroppedShortcutIsRestored() {
        XCTAssertEqual(action(dropped: true), .restoreDropped)
    }

    func testADroppedShortcutIsRestoredEvenDuringATake() {
        XCTAssertEqual(action(dropped: true, take: true), .restoreDropped)
    }

    func testAPendingRegistrationRunsWhenNoTakeIsRunning() {
        XCTAssertEqual(action(pending: true), .reregisterAll)
        XCTAssertEqual(action(pending: true, dropped: true), .reregisterAll)
    }

    /// Taking the trigger's hot key down while it is held for push-to-talk would lose the
    /// release that ends the recording.
    func testAPendingRegistrationWaitsForTheTakeToEnd() {
        XCTAssertEqual(action(pending: true, take: true), .none)
        XCTAssertEqual(action(pending: true, dropped: true, take: true), .restoreDropped)
    }

    func testOnlyTheEndOfSecureInputCounts() {
        XCTAssertTrue(HotkeyKeeper.secureInputEnded(was: true, isNow: false))
        XCTAssertFalse(HotkeyKeeper.secureInputEnded(was: false, isNow: true))
        XCTAssertFalse(HotkeyKeeper.secureInputEnded(was: true, isNow: true))
        XCTAssertFalse(HotkeyKeeper.secureInputEnded(was: false, isNow: false))
    }

    func testAStalePauseIsUndoneWhenNoCaptureIsArmed() {
        XCTAssertEqual(action(paused: true), .resumeLibrary)
        XCTAssertEqual(action(take: true, paused: true), .resumeLibrary)
    }

    func testNothingIsProbedOrRestoredWhileACaptureIsArmed() {
        XCTAssertEqual(action(paused: true, armed: true), .none)
        XCTAssertEqual(action(dropped: true, armed: true), .none)
        XCTAssertEqual(action(pending: true, armed: true), .none)
        XCTAssertEqual(action(armed: true, lost: true), .none)
    }

    func testALostCombinationIsRecovered() {
        XCTAssertEqual(action(lost: true), .recoverLost)
    }

    /// Nothing is registered for a lost combination, so no key-up can be lost.
    func testALostCombinationIsRecoveredDuringATake() {
        XCTAssertEqual(action(take: true, lost: true), .recoverLost)
        XCTAssertEqual(action(pending: true, take: true, lost: true), .recoverLost)
    }

    func testAPendingRegistrationOrADroppedShortcutComesBeforeALostOne() {
        XCTAssertEqual(action(pending: true, lost: true), .reregisterAll)
        XCTAssertEqual(action(dropped: true, lost: true), .restoreDropped)
    }

    func testTheProbeSeesWhetherCarbonHoldsACombination() throws {
        let keyCode = UInt32(kVK_F19)
        let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5445_5354, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        try XCTSkipUnless(status == noErr, "could not register the test combination (\(status))")
        defer { if let ref { UnregisterEventHotKey(ref) } }

        XCTAssertEqual(HotkeyKeeper.probe(keyCode: keyCode, modifiers: modifiers), .held)
        UnregisterEventHotKey(ref)
        ref = nil
        XCTAssertEqual(HotkeyKeeper.probe(keyCode: keyCode, modifiers: modifiers), .free)
    }
}

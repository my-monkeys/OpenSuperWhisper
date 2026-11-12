//
//  HotkeyKeeperTests.swift
//  OpenSuperWhisperTests
//
//  The trigger shortcut could stop answering until the app was relaunched: the shortcut library
//  drops a hot key it fails to put back after a menu closes, and macOS holds back Option
//  shortcuts during secure input. These pin down when the keeper steps in.
//

import XCTest
@testable import OpenSuperWhisper

final class HotkeyKeeperTests: XCTestCase {

    private func action(pending: Bool = false, dropped: Bool = false, take: Bool = false) -> HotkeyKeeper.Action {
        HotkeyKeeper.action(reregisterPending: pending, anyDropped: dropped, takeRunning: take)
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
}

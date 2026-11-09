//
//  StaleStopTests.swift
//  OpenSuperWhisperTests
//
//  The bubble's own stop button must end the take the way the trigger does. It used to leave the
//  shortcut manager believing the take was still running, so the next trigger press sent a
//  second stop to a take that was already transcribing and reported it as lost.
//

import XCTest
@testable import OpenSuperWhisper

@MainActor
final class StaleStopTests: XCTestCase {

    func testStartDecodingOnADecodingTakeStopsNothing() {
        let vm = IndicatorViewModel()
        var stops = 0
        vm.stopRecordingOverride = { stops += 1; return .noAudio }
        vm.state = .decoding

        vm.startDecoding()

        XCTAssertEqual(stops, 0, "a take that is already transcribing has nothing left to stop")
        XCTAssertEqual(vm.state, .decoding, "and must not be reported as lost")
    }

    func testBubbleStopClearsTheActiveTake() {
        let manager = ShortcutManager()
        let vm = IndicatorViewModel()
        var stops = 0
        vm.stopRecordingOverride = { stops += 1; return .tooShort }
        vm.state = .recording
        manager.activeVm = vm
        let windows = IndicatorWindowManager.shared
        let original = windows.viewModel
        windows.viewModel = vm
        defer { windows.viewModel = original; vm.cleanup() }

        manager.stopTakeFromBubble()
        XCTAssertNil(manager.activeVm, "the next trigger press must start a recording, not stop this one again")
        XCTAssertEqual(stops, 1)

        manager.stopTakeFromBubble()
        XCTAssertEqual(stops, 1, "with no take running the bubble's stop does nothing")
    }
}

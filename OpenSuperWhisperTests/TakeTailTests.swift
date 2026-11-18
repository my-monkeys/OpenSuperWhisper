//
//  TakeTailTests.swift
//  OpenSuperWhisperTests
//
//  The microphone stays open a moment after a take ends, so a word finished on the release is
//  not cut short. The take counts as ended at once; only the recorder waits.
//

import XCTest
@testable import OpenSuperWhisper

@MainActor
final class TakeTailTests: XCTestCase {
    private static let tail: TimeInterval = 0.2
    private static let pastTheTail: UInt64 = 450_000_000

    /// A manager running a take whose stops are counted instead of reaching the recorder.
    private func runningTake() -> (ShortcutManager, IndicatorViewModel, () -> Int) {
        let manager = ShortcutManager()
        manager.stopTail = Self.tail
        let vm = IndicatorViewModel()
        var stops = 0
        vm.stopRecordingOverride = { stops += 1; return .tooShort }
        vm.state = .recording
        manager.activeVm = vm
        let windows = IndicatorWindowManager.shared
        let original = windows.viewModel
        windows.viewModel = vm
        addTeardownBlock { @MainActor in
            windows.viewModel = original
            vm.cleanup()
        }
        return (manager, vm, { stops })
    }

    func testTheTakeEndsAtOnceAndTheRecorderStopsAfterTheTail() async throws {
        let (manager, _, stops) = runningTake()

        manager.stopTakeFromBubble()
        XCTAssertNil(manager.activeVm, "the next press must start a new take")
        XCTAssertEqual(stops(), 0, "the recorder is still taking the end of the last word")

        try await Task.sleep(nanoseconds: Self.pastTheTail)
        XCTAssertEqual(stops(), 1)
    }

    func testANewTakeInsideTheTailStopsThePreviousOneFirstAndOnlyOnce() async throws {
        let (manager, _, stops) = runningTake()

        manager.stopTakeFromBubble()
        manager.flushPendingStop()
        XCTAssertEqual(stops(), 1, "the last take lets go of the recorder before the next one starts")

        try await Task.sleep(nanoseconds: Self.pastTheTail)
        XCTAssertEqual(stops(), 1, "the cancelled tail does not stop it a second time")
    }

    func testEscInsideTheTailDropsTheTakeInsteadOfTranscribingIt() async throws {
        let (manager, _, stops) = runningTake()

        manager.stopTakeFromBubble()
        manager.handleEscape()

        try await Task.sleep(nanoseconds: Self.pastTheTail)
        XCTAssertEqual(stops(), 0, "a dropped take is never handed to the transcription")
    }
}

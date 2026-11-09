//
//  RecordingStartAndStopEventsTests.swift
//  OpenSuperWhisperTests
//
//  What the recorder tells the bubble around the edges of a take: a late "recording" after the
//  stop must not revive the bubble, and a start that cannot happen must say why.
//

import AVFoundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingStartAndStopEventsTests: XCTestCase {

    private let recorder = AudioRecorder.shared

    override func tearDown() async throws {
        recorder.isRecording = false
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testARecordingPublicationReachesATakeThatIsStillRunning() async throws {
        let vm = IndicatorViewModel()
        defer { vm.cleanup() }

        recorder.isRecording = true
        try await settle()

        XCTAssertEqual(vm.state, .recording)
    }

    func testALateRecordingPublicationAfterTheStopIsIgnored() async throws {
        let vm = IndicatorViewModel()
        defer { vm.cleanup() }
        vm.stopRecordingOverride = { .tooShort }
        vm.state = .recording
        vm.startDecoding()
        vm.state = .decoding

        recorder.isRecording = true
        try await settle()

        XCTAssertEqual(vm.state, .decoding, "the Bluetooth wait finishing late must not flip the bubble back")
    }

    func testALatePublicationAfterACancelIsIgnored() async throws {
        let vm = IndicatorViewModel()
        defer { vm.cleanup() }
        vm.state = .recording
        vm.cancelRecording()
        vm.state = .idle

        recorder.isRecording = true
        try await settle()

        XCTAssertEqual(vm.state, .idle)
    }

    func testAStartWithNoMicrophoneIsBlocked() {
        XCTAssertNotNil(AudioRecorder.startBlocker(canRecord: false, microphoneAccess: .authorized))
    }

    func testAStartWithMicrophoneAccessDeniedIsBlocked() {
        XCTAssertNotNil(AudioRecorder.startBlocker(canRecord: true, microphoneAccess: .denied))
        XCTAssertNotNil(AudioRecorder.startBlocker(canRecord: true, microphoneAccess: .restricted))
    }

    /// Not yet asked is not a refusal: recording is what raises the system prompt.
    func testAStartThatCanProceedIsNotBlocked() {
        XCTAssertNil(AudioRecorder.startBlocker(canRecord: true, microphoneAccess: .authorized))
        XCTAssertNil(AudioRecorder.startBlocker(canRecord: true, microphoneAccess: .notDetermined))
    }
}

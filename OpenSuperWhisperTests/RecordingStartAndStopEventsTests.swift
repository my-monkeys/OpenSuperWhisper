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

    /// A stop can land on a take that never started: a refused start leaves the bubble showing
    /// the specific reason while the trigger's take is still set, so the user's stop arrives in
    /// `startDecoding`. There is nothing to stop, and the generic "Nothing was recorded" would
    /// replace the reason they need. (#360)
    func testAStopOnARefusedStartLeavesTheReasonAlone() {
        let vm = IndicatorViewModel()
        defer { vm.cleanup() }
        var stops = 0
        vm.stopRecordingOverride = {
            stops += 1
            return .noAudio
        }
        let reason = "Couldn't use the selected microphone. Check that it's connected and try again."
        vm.state = .error(reason)

        vm.startDecoding()

        XCTAssertEqual(stops, 0, "a refused start has no take to stop")
        XCTAssertEqual(vm.state, .error(reason),
                       "the specific reason must survive the stop, not become the generic no-audio message")
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

    /// A switch that fails would leave the take recording from whatever macOS still uses — silent
    /// on a closed laptop lid — and a silent clip is deleted as "no speech", so the user saw
    /// nothing to explain it (#360). This pins the reason the take is refused; the abort that acts
    /// on it lives in `startRecording`.
    func testAFailedMicrophoneSwitchHasAReason() {
        XCTAssertNil(AudioRecorder.microphoneSwitchBlocker(switched: true))
        // The English copy, not a second catalog lookup: this pins the message, and
        // `Scripts/check-localizations.sh` owns catalog completeness.
        // shortcut: English-locale runner assumed; pin the locale if the suite runs elsewhere.
        XCTAssertEqual(AudioRecorder.microphoneSwitchBlocker(switched: false),
                       "Couldn't use the selected microphone. Check that it's connected and try again.")
    }
}

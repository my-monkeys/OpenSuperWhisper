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
    /// `startDecoding`. The body still has to run — the recorder stop restores media and volume
    /// for a take that did open and then died — but the generic "Nothing was recorded" must not
    /// replace the reason the user needs. (#360 review)
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

        XCTAssertEqual(stops, 1, "the body still runs: the recorder stop restores media and volume")
        XCTAssertEqual(vm.state, .error(reason),
                       "the specific reason must survive the stop, not become the generic no-audio message")
    }

    #if DEBUG
    /// The agent reply the trigger armed is handed back in `startDecoding`, before the early
    /// returns that drop a take. A stop on a refused start must give it back too: left armed, the
    /// panel keeps listening and the next dictation, wherever it is aimed, is sent to the agent
    /// as the reply. (#360 review)
    func testAStopOnARefusedStartStillDisarmsTheAgentReply() {
        let vm = IndicatorViewModel()
        defer { vm.cleanup() }
        // The stop now runs the body; keep it off the real recorder.
        vm.stopRecordingOverride = { .noAudio }
        AgentInbox.shared.stageDictation(for: "refused-start")
        defer { AgentInbox.shared.stageDictation(for: nil) }
        XCTAssertEqual(AgentInbox.shared.armedReplyID, "refused-start",
                       "the fixture must arm the reply before the stop, or the assertion below proves nothing")
        vm.state = .error("Couldn't use the selected microphone. Check that it's connected and try again.")

        vm.startDecoding()

        XCTAssertNil(AgentInbox.shared.armedReplyID,
                     "the next dictation must not be taken as the reply to a take that never started")
    }
    #endif

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
    /// nothing to explain it (#360). This pins the reason the take is refused, in the source copy
    /// and in a translated one, so the assertion no longer depends on the runner's language; the
    /// abort that acts on it lives in `startRecording`.
    func testAFailedMicrophoneSwitchHasAReason() {
        XCTAssertNil(AudioRecorder.microphoneSwitchBlocker(switched: true, locale: Locale(identifier: "en")))
        XCTAssertEqual(AudioRecorder.microphoneSwitchBlocker(switched: false, locale: Locale(identifier: "en")),
                       "Couldn't use the selected microphone. Check that it's connected and try again.")
        XCTAssertEqual(AudioRecorder.microphoneSwitchBlocker(switched: false, locale: Locale(identifier: "fr")),
                       "Impossible d'utiliser le micro sélectionné. Vérifiez qu'il est connecté, puis réessayez.")
    }

    /// The decision that replaced trusting the Set's return value: the take may record only when
    /// the chosen device really is the system input after the switch. A transient HAL error that
    /// leaves the chosen device default still records; a switch that landed late, an untranslatable
    /// UID (kAudioObjectUnknown, zero) or another default refuses. (#360 review)
    func testTheTakeContinuesOnlyWhenTheChosenDeviceIsTheSystemInput() {
        // The chosen device is already the default: a failed Set is transient, not a mismatch.
        XCTAssertTrue(AudioRecorder.systemInputIsChosen(targetID: 42, currentDefault: 42))
        // A different default: the switch did not land, so the take would record another device.
        XCTAssertFalse(AudioRecorder.systemInputIsChosen(targetID: 42, currentDefault: 43))
        // An unknown UID translates to kAudioObjectUnknown (0), which is a failure, not a match —
        // and two zeros are not a match either.
        XCTAssertFalse(AudioRecorder.systemInputIsChosen(targetID: nil, currentDefault: 42))
        XCTAssertFalse(AudioRecorder.systemInputIsChosen(targetID: 0, currentDefault: 0))
    }
}

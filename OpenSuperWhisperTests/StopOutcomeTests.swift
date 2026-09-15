//
//  StopOutcomeTests.swift
//  OpenSuperWhisperTests
//
//  What a finished recording produced, and which of the three cases the user hears about.
//  A take that captured nothing used to leave through the same door as a brushed trigger key,
//  which is how a failed dictation came to look exactly like a successful one (#117).
//

import XCTest
@testable import OpenSuperWhisper

final class StopOutcomeTests: XCTestCase {

    private let clip = URL(fileURLWithPath: "/tmp/osw-stop-outcome.wav")

    func testANormalTakeIsAClip() {
        let outcome = AudioRecorder.StopOutcome.of(url: clip, duration: 4.2)

        XCTAssertEqual(outcome.url, clip)
    }

    /// The brushed trigger key. Still dropped in silence, which is the point of the rule.
    func testAVeryShortTakeIsTooShort() {
        guard case .tooShort = AudioRecorder.StopOutcome.of(url: clip, duration: 0.3) else {
            return XCTFail("a third of a second should read as an accidental press")
        }
    }

    /// Zero samples means the recording never began, which costs the user what they said.
    func testAnEmptyTakeIsNoAudio() {
        guard case .noAudio = AudioRecorder.StopOutcome.of(url: clip, duration: 0) else {
            return XCTFail("zero seconds is nothing captured, not a short press")
        }
    }

    /// A file the player cannot open reports zero here. It holds nothing to transcribe either,
    /// so it takes the same door rather than being handed to the engine to fail on later.
    func testAnUnreadableFileIsNoAudio() {
        guard case .noAudio = AudioRecorder.StopOutcome.of(url: nil, duration: 0) else {
            return XCTFail("no file at all is nothing captured")
        }
    }

    /// The boundary itself belongs to the usable side, so a clip of exactly the threshold is
    /// transcribed rather than thrown away.
    func testTheThresholdItselfIsUsable() {
        let outcome = AudioRecorder.StopOutcome.of(url: clip,
                                                   duration: AudioRecorder.minimumUsableDuration)

        XCTAssertEqual(outcome.url, clip)
    }

    /// Only a clip carries a URL. The two failures must not hand one out, or a caller reading
    /// `url` would go on to transcribe a file that was just deleted.
    func testOnlyAClipCarriesAURL() {
        XCTAssertNil(AudioRecorder.StopOutcome.of(url: clip, duration: 0.3).url)
        XCTAssertNil(AudioRecorder.StopOutcome.of(url: clip, duration: 0).url)
    }
}

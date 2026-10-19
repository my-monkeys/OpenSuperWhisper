import XCTest

@testable import OpenSuperWhisper

/// How a meeting's two tracks become one transcript (#159): where speech is found, what counts as
/// the microphone hearing the call, and the document that comes out.
final class MeetingTranscriptTests: XCTestCase {

    private typealias T = MeetingTranscript

    /// Window levels for a track: `true` for a window of speech, `false` for silence.
    private func levels(_ pattern: [(Bool, TimeInterval)]) -> [Float] {
        pattern.flatMap { speech, seconds in
            Array(repeating: speech ? Float(0.05) : 0, count: Int((seconds / T.frameLength).rounded()))
        }
    }

    private func utterance(_ speaker: T.Speaker, _ start: TimeInterval, _ text: String) -> T.Utterance {
        .init(speaker: speaker, start: start, end: start + 3, text: text)
    }

    func testSilenceHasNoPassage() {
        XCTAssertEqual(T.passages(levels: levels([(false, 10)])), [])
    }

    func testASentenceWithShortPausesIsOnePassage() throws {
        let found = T.passages(levels: levels([(false, 1), (true, 2), (false, 0.5), (true, 1.5), (false, 2)]))
        XCTAssertEqual(found.count, 1)
        let passage = try XCTUnwrap(found.first)
        XCTAssertEqual(passage.lowerBound, 1, accuracy: 0.05)
        XCTAssertEqual(passage.upperBound, 5, accuracy: 0.05)
    }

    func testALongPauseSplitsPassages() {
        XCTAssertEqual(T.passages(levels: levels([(true, 2), (false, 2), (true, 2)])).count, 2)
    }

    func testAClickIsNotAPassage() {
        XCTAssertEqual(T.passages(levels: levels([(false, 1), (true, 0.2), (false, 3)])), [])
    }

    func testALongMonologueIsCutSoTimestampsStayClose() {
        let found = T.passages(levels: levels([(true, 60)]))
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.upperBound - $0.lowerBound <= T.longestPassage + 0.001 })
    }

    func testFrameLevelsMeasureLoudness() {
        let quiet = T.frameLevels(Array(repeating: 0.001, count: 480))
        let loud = T.frameLevels(Array(repeating: 0.2, count: 480))
        XCTAssertLessThan(quiet[0], T.speechLevel)
        XCTAssertGreaterThan(loud[0], T.speechLevel)
    }

    /// Without headphones the microphone hears the call: the same words, at the same moment.
    func testTheMicrophoneHearingTheCallIsDropped() {
        let merged = T.merged([
            utterance(.others, 10, "Can everyone see my screen?"),
            utterance(.me, 10.4, "everyone see my screen"),
        ])
        XCTAssertEqual(merged.map(\.speaker), [.others])
    }

    func testYourOwnAnswerIsKept() {
        let merged = T.merged([
            utterance(.others, 10, "Can everyone see my screen?"),
            utterance(.me, 13, "Yes, it's showing the roadmap."),
        ])
        XCTAssertEqual(merged.map(\.speaker), [.others, .me])
    }

    func testTurnsComeInTimeOrderAndOneSpeakersPassagesJoin() {
        let merged = T.merged([
            utterance(.me, 20, "Second part."),
            utterance(.others, 30, "Thanks."),
            utterance(.me, 5, "First part."),
        ])
        XCTAssertEqual(merged.map(\.text), ["First part. Second part.", "Thanks."])
        XCTAssertEqual(merged.first?.start, 5)
    }

    func testTheDocumentHasTimesAndSpeakers() {
        let text = T.markdown([utterance(.me, 65, "Hello."), utterance(.others, 3_725, "Bye.")],
                              startedAt: Date(timeIntervalSince1970: 1_760_000_000), duration: 3_730,
                              me: "Me", others: "Others")
        XCTAssertTrue(text.hasPrefix("# "))
        XCTAssertTrue(text.contains("**[00:01:05] Me:** Hello."), text)
        XCTAssertTrue(text.contains("**[01:02:05] Others:** Bye."), text)
        XCTAssertTrue(text.contains("01:02:10"), text)
    }
}

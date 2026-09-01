import XCTest

@testable import OpenSuperWhisper

/// Feeding the transcriber what the user was already writing.
///
/// The value of this is that names and terms already on the page stop being guessed at. The
/// risk is that it reads someone's document, so the tests care as much about when it declines
/// as about when it works.
final class SurroundingContextTests: XCTestCase {

    // MARK: - Deciding whether to use it at all

    func testNothingIsUsedWhenTheSettingIsOff() {
        XCTAssertNil(TranscriptionPrompt.surroundingText(enabled: false,
                                                         captured: "Bunny insisted"))
    }

    func testNothingIsUsedWhenNothingWasCaptured() {
        XCTAssertNil(TranscriptionPrompt.surroundingText(enabled: true, captured: nil))
        XCTAssertNil(TranscriptionPrompt.surroundingText(enabled: true, captured: ""))
    }

    func testTheCapturedTextIsUsedWhenBothHold() {
        XCTAssertEqual(TranscriptionPrompt.surroundingText(enabled: true,
                                                           captured: "Bunny insisted"),
                       "Bunny insisted")
    }

    // MARK: - Assembling the prompt

    /// Whisper reads the prompt as the words just before the audio, so what the user was in the
    /// middle of writing has to sit closest to what they are about to say.
    func testTheSurroundingTextComesLast() {
        let prompt = TranscriptionPrompt.combined(userPrompt: "Write in British English.",
                                                  dictionaryBoost: "GitHub, Kubernetes",
                                                  surroundingText: "Charity had never cared for")

        XCTAssertEqual(prompt,
                       "Write in British English. GitHub, Kubernetes Charity had never cared for")
    }

    func testEmptySourcesAreLeftOut() {
        XCTAssertEqual(TranscriptionPrompt.combined(userPrompt: "",
                                                    dictionaryBoost: "GitHub",
                                                    surroundingText: nil),
                       "GitHub")
    }

    func testNoSourcesMeansNoPrompt() {
        XCTAssertNil(TranscriptionPrompt.combined(userPrompt: "   ",
                                                  dictionaryBoost: "",
                                                  surroundingText: nil))
    }

    func testWhitespaceDoesNotBecomeDoubleSpacing() {
        let prompt = TranscriptionPrompt.combined(userPrompt: "  a standing note  ",
                                                  dictionaryBoost: "",
                                                  surroundingText: "  the sentence so far ")

        XCTAssertEqual(prompt, "a standing note the sentence so far")
    }

    // MARK: - Slicing what was read out of the field

    func testOnlyTheTextBeforeTheCaretIsTaken() {
        let text = "Charity had never cared for bonfires, but Bunny insisted."

        XCTAssertEqual(SourceCapture.tail(of: text, upTo: 27), "Charity had never cared for")
    }

    func testACaretAtTheStartYieldsNothing() {
        XCTAssertNil(SourceCapture.tail(of: "Charity had never", upTo: 0))
    }

    /// AX can report a caret past the end while a field is being rebuilt, and an out-of-range
    /// slice would trap rather than degrade.
    func testACaretPastTheEndIsClamped() {
        XCTAssertEqual(SourceCapture.tail(of: "Bunny insisted", upTo: 9_000), "Bunny insisted")
    }

    func testANegativeCaretIsHarmless() {
        XCTAssertNil(SourceCapture.tail(of: "Bunny insisted", upTo: -3))
    }

    func testLongFieldsAreCappedToTheTail() {
        let long = String(repeating: "word ", count: 500)
        let slice = SourceCapture.tail(of: long, upTo: long.count)

        XCTAssertNotNil(slice)
        XCTAssertLessThanOrEqual(slice!.count, SourceCapture.focusedTextLimit)
    }

    /// A cut landing inside a word would hand the model half a token as though it were whole.
    func testTheCutDoesNotLandMidWord() {
        let text = String(repeating: "a", count: 300) + " Bunny insisted on bonfires"
        let slice = SourceCapture.tail(of: text, upTo: text.count)

        XCTAssertEqual(slice, "Bunny insisted on bonfires")
    }

    func testAFieldOfOnlyWhitespaceYieldsNothing() {
        XCTAssertNil(SourceCapture.tail(of: "   \n  ", upTo: 6))
    }

    // MARK: - What the engines are allowed to see

    /// The remote engine posts the prompt to whatever endpoint the user configured, so the
    /// surrounding text must reach the local prompt assembly and nothing else. This pins the
    /// separation: the setting never writes into `initialPrompt`, which is the field the remote
    /// engine reads.
    func testTheStandingPromptIsNeverRewritten() {
        let before = AppPreferences.shared.initialPrompt
        _ = TranscriptionPrompt.combined(userPrompt: before,
                                         dictionaryBoost: "",
                                         surroundingText: "a private sentence")

        XCTAssertEqual(AppPreferences.shared.initialPrompt, before)
    }

    func testTheSettingIsOffUntilAskedFor() {
        // Reading what someone is writing is not a sensible default.
        let fresh = UserDefaults(suiteName: "surrounding-context-default-\(UUID().uuidString)")!
        XCTAssertFalse(fresh.bool(forKey: "useSurroundingTextAsContext"))
    }
}

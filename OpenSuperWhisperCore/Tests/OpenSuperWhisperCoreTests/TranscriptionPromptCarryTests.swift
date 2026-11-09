import XCTest
@testable import OpenSuperWhisperCore

/// Carrying the prompt into later windows is only worth it while the rolling history still fits
/// beside it. Whisper's text context is 448 tokens, of which a window's prompt may use half.
final class TranscriptionPromptCarryTests: CoreTestCase {

    private let whisperTextContext = 448

    func testAShortPromptIsCarried() {
        XCTAssertTrue(TranscriptionPrompt.canCarry(promptTokens: 30, textContext: whisperTextContext))
    }

    func testThePromptIsCarriedUpToAQuarterOfTheContext() {
        XCTAssertTrue(TranscriptionPrompt.canCarry(promptTokens: 111, textContext: whisperTextContext))
        XCTAssertFalse(TranscriptionPrompt.canCarry(promptTokens: 112, textContext: whisperTextContext),
                       "past it the history would be left with less than half the window")
    }

    func testAHugePromptIsNotCarried() {
        XCTAssertFalse(TranscriptionPrompt.canCarry(promptTokens: 400, textContext: whisperTextContext))
    }

    func testNoPromptHasNothingToCarry() {
        XCTAssertFalse(TranscriptionPrompt.canCarry(promptTokens: 0, textContext: whisperTextContext))
    }

    func testTheBudgetFollowsTheModelsContext() {
        XCTAssertTrue(TranscriptionPrompt.canCarry(promptTokens: 60, textContext: 448))
        XCTAssertFalse(TranscriptionPrompt.canCarry(promptTokens: 60, textContext: 224))
    }
}

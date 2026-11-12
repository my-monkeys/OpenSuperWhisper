import XCTest
@testable import OpenSuperWhisperCore

/// A reply that stopped on a length limit is a failed cleanup, on every backend: pasting it drops
/// the end of the dictation without a word (feedback of 2026-11-11, built-in model capped at 512
/// tokens). No model here; `CoreLlamaCompletionTests` runs the real one.
final class CleanupCutReplyTests: CoreTestCase {

    private static let input = "so this is the raw transcription of a dictation"

    private struct ThrowingBackend: LLMCleanupBackend {
        let error: Error
        var isReady: Bool { true }
        var modelLabel: String { "org/fake-model" }
        func generate(system: String, user: String) async throws -> String { throw error }
    }

    // MARK: - Built-in model

    func testABudgetSizedOnTheInputLeavesRoomForALongDictation() {
        // About three minutes of speech, which the old flat 512 cut in the middle.
        XCTAssertGreaterThan(LlamaContext.replyBudget(inputTokens: 700), 700 * 2)
    }

    func testOnlyAFinishedCompletionIsAReply() throws {
        XCTAssertEqual(try BuiltInLlamaBackend.reply(to: .init(text: "Cleaned.", stop: .finished)), "Cleaned.")
        XCTAssertThrowsError(try BuiltInLlamaBackend.reply(to: .init(text: "Clea", stop: .tokenBudget))) {
            XCTAssertEqual($0 as? CleanupReplyError, .cutOff)
        }
        XCTAssertThrowsError(try BuiltInLlamaBackend.reply(to: .init(text: "", stop: .promptTooLong))) {
            XCTAssertEqual($0 as? CleanupReplyError, .tooLong)
        }
        XCTAssertThrowsError(try BuiltInLlamaBackend.reply(to: .init(text: "Clea", stop: .decodeFailed)))
    }

    // MARK: - OpenAI-compatible servers

    func testAChatCompletionThatStoppedOnItsLimitIsCutOff() {
        let body = Data(#"{"choices":[{"message":{"content":"Half of it"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertThrowsError(try LLMPostProcessor.chatReply(from: body)) {
            XCTAssertEqual($0 as? CleanupReplyError, .cutOff)
        }
    }

    func testAFinishedChatCompletionIsTheReply() throws {
        let stopped = Data(#"{"choices":[{"message":{"content":"All of it"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try LLMPostProcessor.chatReply(from: stopped), "All of it")
        // Some compatible servers leave the field out.
        let bare = Data(#"{"choices":[{"message":{"content":"All of it"}}]}"#.utf8)
        XCTAssertEqual(try LLMPostProcessor.chatReply(from: bare), "All of it")
    }

    func testAnUnreadableChatCompletionThrows() {
        XCTAssertThrowsError(try LLMPostProcessor.chatReply(from: Data(#"{"nope":1}"#.utf8)))
    }

    // MARK: - Ollama

    func testAnOllamaReplyThatStoppedOnItsLimitIsCutOff() {
        let body = Data(#"{"message":{"role":"assistant","content":"Half"},"done":true,"done_reason":"length"}"#.utf8)
        XCTAssertThrowsError(try OllamaBackend.reply(from: body)) {
            XCTAssertEqual($0 as? CleanupReplyError, .cutOff)
        }
    }

    func testAFinishedOllamaReplyIsTheReply() throws {
        let body = Data(#"{"message":{"role":"assistant","content":"All"},"done":true,"done_reason":"stop"}"#.utf8)
        XCTAssertEqual(try OllamaBackend.reply(from: body), "All")
    }

    // MARK: - What the dictation gets

    func testACutReplyLeavesTheDictationAsHeardAndSaysWhy() async {
        CoreTestEnvironment.preferences.aiPostProcessingEnabled = true
        let outcome = await LLMPostProcessor.run(Self.input, bundleID: nil, translating: false,
                                                 writesLists: false, style: "",
                                                 backend: ThrowingBackend(error: CleanupReplyError.cutOff))
        XCTAssertEqual(outcome.text, Self.input)
        XCTAssertEqual(outcome.status, .failed(model: "org/fake-model", reason: "Reply cut off before the end"))
    }
}

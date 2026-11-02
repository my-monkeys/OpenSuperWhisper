import XCTest
import os
@testable import OpenSuperWhisperCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Stands in for Apple's on-device model: answers with a canned reply and records what it was
/// asked. Counts one token per character unless told otherwise, so the context arithmetic is
/// easy to set up.
final class StubOnDeviceModel: OnDeviceLanguageModel, @unchecked Sendable {
    struct Call: Equatable { let instructions: String; let prompt: String }

    let availability: AppleIntelligenceAvailability
    let contextSize: Int
    private let reply: Result<String, Error>
    private let supported: Set<String>
    private let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])

    init(availability: AppleIntelligenceAvailability = .available, contextSize: Int = 4096,
         reply: Result<String, Error> = .success("Cleaned."), supported: Set<String> = ["en", "fr"]) {
        self.availability = availability
        self.contextSize = contextSize
        self.reply = reply
        self.supported = supported
    }

    var received: [Call] { calls.withLock { $0 } }

    func supportsLanguage(_ code: String) -> Bool { supported.contains(code) }

    func tokenCount(of text: String) async -> Int { text.count }

    func respond(instructions: String, prompt: String) async throws -> String {
        calls.withLock { $0.append(Call(instructions: instructions, prompt: prompt)) }
        return try reply.get()
    }
}

/// Apple Intelligence as a cleanup engine (#158): which backend a preference selects, how the
/// model's availability reads, the context-window guard, and that every way it can't run hands
/// back the transcription untouched. The real model is never called.
final class AppleIntelligenceCleanupTests: CoreTestCase {

    private static let input = "so this is the raw transcription of a dictation"
    private struct ModelFailure: Error {}

    private var prefs: TestPreferences { CoreTestEnvironment.preferences }

    override func setUp() {
        super.setUp()
        prefs.aiBackend = "apple"
        prefs.aiPostProcessingEnabled = true
        prefs.aiPostProcessingPrompt = "OPEN"
        prefs.aiPostProcessingClosing = "CLOSE"
        // The instructions here are the two halves; the spoken punctuation section has its own
        // tests (`SpokenFormattingPromptTests`).
        prefs.aiSpokenFormattingEnabled = false
    }

    override func tearDown() {
        AppleIntelligence.replaceModelForTesting(nil)
        super.tearDown()
    }

    @discardableResult
    private func install(_ model: StubOnDeviceModel) -> StubOnDeviceModel {
        AppleIntelligence.replaceModelForTesting(model)
        return model
    }

    // MARK: - Default backend

    func testNeverChosenResolvesToAppleOnlyWhereAvailable() {
        XCTAssertEqual(LLMPostProcessor.effectiveBackend(stored: nil, appleIntelligence: .available), "apple")
        let unavailable: [AppleIntelligenceAvailability] = [
            .unsupportedMac, .turnedOff, .modelNotReady, .unsupportedLanguage("cy"),
        ]
        for availability in unavailable {
            XCTAssertEqual(LLMPostProcessor.effectiveBackend(stored: nil, appleIntelligence: availability),
                           "ollama", "\(availability)")
        }
    }

    /// An explicit choice always wins, the old Ollama default included.
    func testExplicitChoiceIsKeptWhateverTheAvailability() {
        for stored in ["builtin", "ollama", "remote", "apple", ""] {
            for availability in [AppleIntelligenceAvailability.available, .unsupportedMac] {
                XCTAssertEqual(LLMPostProcessor.effectiveBackend(stored: stored, appleIntelligence: availability),
                               stored, "\(stored) / \(availability)")
            }
        }
    }

    // MARK: - Selection

    func testAppleSelectsTheOnDeviceBackend() throws {
        let model = install(StubOnDeviceModel())
        let backend = try XCTUnwrap(LLMPostProcessor.currentBackend() as? AppleIntelligenceBackend)
        XCTAssertTrue(backend.model as? StubOnDeviceModel === model)
        XCTAssertFalse(backend.enforcesLengthRatio, "a hosted-class model is not second-guessed on length")
    }

    // MARK: - Availability

    func testAvailabilityWithoutAModelIsAnUnsupportedMac() {
        XCTAssertEqual(AppleIntelligence.availability(of: nil, language: "en"), .unsupportedMac)
        XCTAssertFalse(AppleIntelligenceBackend(model: nil).isReady)
    }

    func testAvailabilityPassesTheSystemReasonThrough() {
        for reason in [AppleIntelligenceAvailability.unsupportedMac, .turnedOff, .modelNotReady] {
            let model = StubOnDeviceModel(availability: reason)
            XCTAssertEqual(AppleIntelligence.availability(of: model, language: "en"), reason)
        }
    }

    func testUnsupportedLanguageIsReportedOnlyOnceTheModelRuns() {
        let model = StubOnDeviceModel(supported: ["en"])
        XCTAssertEqual(AppleIntelligence.availability(of: model, language: "cy"), .unsupportedLanguage("cy"))
        XCTAssertEqual(AppleIntelligence.availability(of: model, language: "en"), .available)
        let off = StubOnDeviceModel(availability: .turnedOff, supported: ["en"])
        XCTAssertEqual(AppleIntelligence.availability(of: off, language: "cy"), .turnedOff,
                       "the reason the user has to fix first")
    }

    /// The detected language isn't known before transcription, so auto-detect checks nothing.
    func testAutoDetectSkipsTheLanguageCheck() {
        let model = StubOnDeviceModel(supported: [])
        for language in ["auto", "", nil] as [String?] {
            XCTAssertEqual(AppleIntelligence.availability(of: model, language: language), .available,
                           String(describing: language))
        }
    }

#if canImport(FoundationModels)
    func testSystemAvailabilityMapping() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        XCTAssertEqual(AppleIntelligenceAvailability(.available), .available)
        XCTAssertEqual(AppleIntelligenceAvailability(.unavailable(.deviceNotEligible)), .unsupportedMac)
        XCTAssertEqual(AppleIntelligenceAvailability(.unavailable(.appleIntelligenceNotEnabled)), .turnedOff)
        XCTAssertEqual(AppleIntelligenceAvailability(.unavailable(.modelNotReady)), .modelNotReady)
    }
#endif

    // MARK: - Context window

    func testFitsContextCountsTheReplyAsLongAsTheText() {
        let overhead = AppleIntelligence.templateOverheadTokens
        XCTAssertTrue(AppleIntelligence.fitsContext(instructionTokens: 1000, textTokens: 1000,
                                                    contextSize: 3000 + overhead))
        XCTAssertFalse(AppleIntelligence.fitsContext(instructionTokens: 1000, textTokens: 1001,
                                                     contextSize: 3000 + overhead))
    }

    func testTokenEstimateErrsHighForSpacedAndDenseScripts() {
        XCTAssertEqual(AppleIntelligence.estimatedTokenCount(""), 0)
        XCTAssertEqual(AppleIntelligence.estimatedTokenCount("abc"), 1)
        XCTAssertEqual(AppleIntelligence.estimatedTokenCount("abcd"), 2)
        let english = String(repeating: "word ", count: 300)
        XCTAssertGreaterThanOrEqual(AppleIntelligence.estimatedTokenCount(english), english.count / 4,
                                    "never below the tokenizer's typical four characters per token")
        XCTAssertEqual(AppleIntelligence.estimatedTokenCount("今日は良い天気です"), 9, "one per character")
    }

    // MARK: - process

    /// The same prompt contract as every backend: the assembled system prompt as instructions,
    /// the transcription untouched as the prompt, and the trimmed reply back.
    func testCleansWithTheAssembledPromptAndTrimsTheReply() async {
        let model = install(StubOnDeviceModel(reply: .success("  Cleaned.\n")))

        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

        XCTAssertEqual(result, "Cleaned.")
        XCTAssertEqual(model.received, [.init(instructions: "OPEN\n\nCLOSE", prompt: Self.input)])
    }

    func testAppRulesAndTranslationReachTheInstructions() async {
        prefs.appContextFormattingEnabled = true
        prefs.appContextProfiles = [AppContextProfile(bundleIdentifier: "com.example.app", instructions: "RULES")]
        prefs.aiPostProcessingTranslation = "TRANSLATED"
        let model = install(StubOnDeviceModel())

        _ = await LLMPostProcessor.process(Self.input, bundleID: "com.example.app", translating: true)

        XCTAssertEqual(model.received.first?.instructions,
                       "OPEN\n\nTRANSLATED\n\nApp-specific formatting rules:\nRULES\n\nCLOSE")
    }

    func testUnavailableModelReturnsTheInputWithoutCallingIt() async {
        for reason in [AppleIntelligenceAvailability.unsupportedMac, .turnedOff, .modelNotReady] {
            let model = install(StubOnDeviceModel(availability: reason))

            let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

            XCTAssertEqual(result, Self.input, "\(reason)")
            XCTAssertTrue(model.received.isEmpty, "\(reason)")
        }
    }

    func testGenerateRefusesWithoutAModel() async {
        do {
            _ = try await AppleIntelligenceBackend(model: nil).generate(system: "OPEN", user: Self.input)
            XCTFail("generate must refuse without a model")
        } catch {
            XCTAssertEqual(error as? AppleIntelligenceBackend.Failure, .unavailable(.unsupportedMac))
        }
    }

    /// A dictation that doesn't fit is sent back raw, never truncated, and the model isn't asked.
    func testTooLongForTheContextReturnsTheInputUntouched() async {
        let instructions = "OPEN\n\nCLOSE".count
        let overhead = AppleIntelligence.templateOverheadTokens
        let fits = String(repeating: "a", count: 100)
        let contextSize = instructions + 2 * fits.count + overhead
        let model = install(StubOnDeviceModel(contextSize: contextSize))

        let kept = await LLMPostProcessor.process(fits, bundleID: nil)
        XCTAssertEqual(kept, "Cleaned.", "exactly at the limit still runs")
        XCTAssertEqual(model.received.count, 1)

        let tooLong = fits + "a"
        let result = await LLMPostProcessor.process(tooLong, bundleID: nil)
        XCTAssertEqual(result, tooLong)
        XCTAssertEqual(model.received.count, 1, "the model is not asked")
    }

    func testTooLongThrowsWithTheNumbersForTheLog() async {
        let model = StubOnDeviceModel(contextSize: 100)
        do {
            _ = try await AppleIntelligenceBackend(model: model).generate(system: "OPEN", user: String(repeating: "a", count: 50))
            XCTFail("expected the context guard to refuse")
        } catch {
            XCTAssertEqual(error as? AppleIntelligenceBackend.Failure,
                           .exceedsContext(tokens: 4 + 100 + AppleIntelligence.templateOverheadTokens, contextSize: 100))
        }
    }

    /// Errors, refusals and guardrail hits all surface as a thrown error: the raw text comes back.
    func testModelErrorReturnsTheInput() async {
        install(StubOnDeviceModel(reply: .failure(ModelFailure())))
        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)
        XCTAssertEqual(result, Self.input)
    }

    func testBlankReplyReturnsTheInput() async {
        install(StubOnDeviceModel(reply: .success(" \n ")))
        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)
        XCTAssertEqual(result, Self.input)
    }

    func testCleanupOffNeverAsksTheModel() async {
        prefs.aiPostProcessingEnabled = false
        let model = install(StubOnDeviceModel())
        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)
        XCTAssertEqual(result, Self.input)
        XCTAssertTrue(model.received.isEmpty)
    }
}

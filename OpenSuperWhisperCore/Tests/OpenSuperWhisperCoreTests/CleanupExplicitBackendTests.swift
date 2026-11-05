import XCTest
import os
@testable import OpenSuperWhisperCore

/// Rerunning the cleanup from the history (#276): on a backend chosen for this pass, with an
/// instruction that belongs to this pass alone.
final class CleanupExplicitBackendTests: CoreTestCase {
    private final class RecordingBackend: LLMCleanupBackend, @unchecked Sendable {
        let isReady = true
        let modelLabel: String
        let reply: String
        private let systems = OSAllocatedUnfairLock(initialState: [String]())
        var lastSystem: String? { systems.withLock { $0.last } }

        init(label: String, reply: String) {
            modelLabel = label
            self.reply = reply
        }

        func generate(system: String, user: String) async throws -> String {
            systems.withLock { $0.append(system) }
            return reply
        }
    }

    private var prefs: TestPreferences { CoreTestEnvironment.preferences }

    override func setUp() {
        super.setUp()
        prefs.aiPostProcessingEnabled = true
        prefs.aiPostProcessingPrompt = "OPEN"
        prefs.aiPostProcessingClosing = "CLOSE"
        prefs.appContextFormattingEnabled = false
        // These pin where the extra instruction sits between the halves; the spoken punctuation
        // section has its own tests (`SpokenFormattingPromptTests`).
        prefs.aiSpokenFormattingEnabled = false
    }

    func testThePassRunsOnTheGivenBackendAndNamesIt() async {
        let backend = RecordingBackend(label: "other-model", reply: "Hello there.")
        let outcome = await LLMPostProcessor.processWithOutcome("hello there", bundleID: nil, backend: backend)
        XCTAssertEqual(outcome, CleanupOutcome(text: "Hello there.", status: .cleaned(model: "other-model")))
    }

    func testAResolvedOnRunsAPassEvenWhileTheGlobalSwitchIsOff() async {
        prefs.aiPostProcessingEnabled = false
        let backend = RecordingBackend(label: "m", reply: "Hello there.")
        let outcome = await LLMPostProcessor.processWithOutcome("hello there", bundleID: nil,
                                                                generalCleanup: true, backend: backend)
        XCTAssertEqual(outcome.text, "Hello there.")
        XCTAssertEqual(backend.lastSystem, "OPEN\n\nCLOSE")
    }

    func testAResolvedOffSkipsThePassWhileTheGlobalSwitchIsOn() async {
        let backend = RecordingBackend(label: "m", reply: "Hello there.")
        let outcome = await LLMPostProcessor.processWithOutcome("hello there", bundleID: nil,
                                                                generalCleanup: false, backend: backend)
        XCTAssertEqual(outcome, CleanupOutcome(text: "hello there", status: .notRun))
        XCTAssertNil(backend.lastSystem)
    }

    func testNoResolvedValueFollowsTheGlobalSwitch() async {
        prefs.aiPostProcessingEnabled = false
        let backend = RecordingBackend(label: "m", reply: "Hello there.")
        let outcome = await LLMPostProcessor.processWithOutcome("hello there", bundleID: nil, backend: backend)
        XCTAssertEqual(outcome.status, .notRun)
    }

    func testTheExtraInstructionComesAfterTheStyleAndBeforeTheClosingGuardrail() async throws {
        let backend = RecordingBackend(label: "m", reply: "Hello there.")
        _ = await LLMPostProcessor.processWithOutcome("hello there", bundleID: nil, style: "STYLE",
                                                      extraInstruction: "EXTRA", backend: backend)
        let system = try XCTUnwrap(backend.lastSystem)
        XCTAssertEqual(system, "OPEN\n\nSTYLE\n\nEXTRA\n\nCLOSE")
    }

    func testNoExtraInstructionLeavesThePromptAsItWas() async throws {
        let backend = RecordingBackend(label: "m", reply: "Hello there.")
        _ = await LLMPostProcessor.processWithOutcome("hello there", bundleID: nil, style: "STYLE", backend: backend)
        XCTAssertEqual(backend.lastSystem, "OPEN\n\nSTYLE\n\nCLOSE")
    }

    func testTheExtraInstructionIsNotPartOfTheShippedTextTheEchoGuardKnows() {
        let shipped = LLMPostProcessor.shippedInstructions(
            generalCleanup: true, generalPrompt: LLMPostProcessor.defaultInstruction, profile: nil,
            closingPrompt: LLMPostProcessor.defaultClosingInstruction, translating: false, translationPrompt: "")
        XCTAssertFalse(shipped.contains("EXTRA"))
    }

    func testAReplyThatRepeatsOnlyTheExtraInstructionIsNotTreatedAsAnEcho() async {
        let extra = "Write every sentence as a short question about the weather in Lisbon this week."
        let backend = RecordingBackend(label: "m", reply: extra)
        let outcome = await LLMPostProcessor.processWithOutcome("is it sunny", bundleID: nil,
                                                                extraInstruction: extra, backend: backend)
        XCTAssertEqual(outcome.status, .cleaned(model: "m"),
                       "the user's own words are not shipped text, so repeating them is what they asked for")
    }

    func testTheBackendFactoryReplacesTheModelOfOllamaAndRemoteOnly() {
        prefs.aiOllamaModel = "llama3.2"
        prefs.aiRemoteModel = "configured"
        XCTAssertEqual(LLMPostProcessor.backend("ollama").modelLabel, "llama3.2")
        XCTAssertEqual(LLMPostProcessor.backend("ollama", model: "qwen3").modelLabel, "qwen3")
        XCTAssertEqual(LLMPostProcessor.backend("remote", model: "google/gemini").modelLabel, "google/gemini")
        XCTAssertEqual(LLMPostProcessor.backend("remote").modelLabel, "configured")
        XCTAssertEqual(LLMPostProcessor.backend("apple", model: "ignored").modelLabel, "Apple Intelligence")
    }
}

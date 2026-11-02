import os
import XCTest
@testable import OpenSuperWhisperCore

/// Spoken punctuation and layout (#265): when the cleanup model is asked to turn "virgule" or
/// "entre parenthèses" into what they mean, and where that request sits in the prompt.
final class SpokenFormattingPromptTests: CoreTestCase {

    private let slack = AppContextProfile(bundleIdentifier: "com.tinyspeck.slackmacgap",
                                          appName: "Slack", instructions: "Slack rules.")

    /// Keeps the system prompt it was sent, and answers with the dictation unchanged.
    private final class PromptCatcher: LLMCleanupBackend, @unchecked Sendable {
        let isReady = true
        let modelLabel = "catcher"
        private let sent = OSAllocatedUnfairLock<String?>(initialState: nil)
        var system: String? { sent.withLock { $0 } }

        func generate(system: String, user: String) async throws -> String {
            sent.withLock { $0 = system }
            return user
        }
    }

    private var prefs: TestPreferences { CoreTestEnvironment.preferences }

    private func sentPrompt() async -> String? {
        let catcher = PromptCatcher()
        _ = await LLMPostProcessor.run("je vais faire à manger entre parenthèses patates frites",
                                       bundleID: "com.tinyspeck.slackmacgap", translating: false,
                                       writesLists: false, style: "", backend: catcher)
        return catcher.system
    }

    func testAskedForWhileCleanupIsOn() async throws {
        prefs.aiPostProcessingEnabled = true
        let system = try await XCTUnwrap(sentPrompt())
        XCTAssertTrue(system.contains(LLMPostProcessor.spokenFormattingInstruction))
    }

    func testNotAskedForWhenTheSwitchIsOff() async throws {
        prefs.aiPostProcessingEnabled = true
        prefs.aiSpokenFormattingEnabled = false
        let system = try await XCTUnwrap(sentPrompt())
        XCTAssertFalse(system.contains(LLMPostProcessor.spokenFormattingInstruction))
    }

    /// A pass started by the app rules alone does what the rules say, nothing of general cleanup.
    func testNotAskedForWhenOnlyAppFormattingRuns() async throws {
        prefs.aiPostProcessingEnabled = false
        prefs.appContextFormattingEnabled = true
        prefs.appContextProfiles = [slack]
        let system = try await XCTUnwrap(sentPrompt())
        XCTAssertFalse(system.contains(LLMPostProcessor.spokenFormattingInstruction))
    }

    /// The app's rules and the guardrail keep the last word.
    func testTheRequestComesBeforeTheAppRulesAndTheGuardrail() throws {
        let system = try XCTUnwrap(LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "Opening.", profile: slack,
            closingPrompt: "Closing.", spokenFormatting: true))
        let request = try XCTUnwrap(system.range(of: LLMPostProcessor.spokenFormattingInstruction)).lowerBound
        let rules = try XCTUnwrap(system.range(of: "Slack rules.")).lowerBound
        let closing = try XCTUnwrap(system.range(of: "Closing.")).lowerBound
        XCTAssertLessThan(request, rules)
        XCTAssertLessThan(rules, closing)
    }

    /// An echo of the request is caught like any other shipped instruction.
    func testTheRequestCountsAsShippedText() {
        let shipped = LLMPostProcessor.shippedInstructions(
            generalCleanup: true, generalPrompt: "", profile: nil, closingPrompt: "",
            translating: false, translationPrompt: "", spokenFormatting: true)
        XCTAssertTrue(shipped.contains(LLMPostProcessor.spokenFormattingInstruction))
    }
}

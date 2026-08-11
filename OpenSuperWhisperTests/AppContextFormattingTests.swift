import XCTest
@testable import OpenSuperWhisper

/// Covers the pure logic behind app-aware LLM formatting: profile lookup by bundle id, system
/// prompt assembly from the two independent contributors (general cleanup + per-app rules), and
/// the output length guard. The LLM call itself is I/O and is verified manually.
final class AppContextFormattingTests: XCTestCase {

    private let slack = AppContextProfile(
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        appName: "Slack",
        instructions: "Convert \"at Rob\" to \"@Rob\" and \"slash giphy\" to \"/giphy\".")

    private let terminal = AppContextProfile(
        bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal",
        instructions: "Lowercase shell commands.")

    private lazy var profiles = [slack, terminal]

    // MARK: - profile(for:in:)

    func testProfileExactMatch() {
        let match = LLMPostProcessor.profile(for: "com.tinyspeck.slackmacgap", in: profiles)
        XCTAssertEqual(match, slack)
    }

    func testProfileCaseInsensitiveMatch() {
        let match = LLMPostProcessor.profile(for: "COM.TINYSPECK.SlackMacGap", in: profiles)
        XCTAssertEqual(match, slack)
    }

    func testProfileNilBundleID() {
        XCTAssertNil(LLMPostProcessor.profile(for: nil, in: profiles))
    }

    func testProfileNoMatch() {
        XCTAssertNil(LLMPostProcessor.profile(for: "com.unknown.app", in: profiles))
    }

    // MARK: - assembleSystemPrompt

    func testAssembleBothOffReturnsNil() {
        XCTAssertNil(LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: false, generalPrompt: "GENERAL", profile: nil))
    }

    func testAssembleGeneralOnly() {
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "FIX-PUNCTUATION", profile: nil)
        XCTAssertNotNil(system)
        XCTAssertTrue(system!.contains("FIX-PUNCTUATION"))
        // No app profile → no app-specific section.
        XCTAssertFalse(system!.contains("App-specific"))
    }

    func testAssembleFormattingOnly() {
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: false, generalPrompt: "FIX-PUNCTUATION", profile: slack)
        XCTAssertNotNil(system)
        XCTAssertTrue(system!.contains(slack.instructions))
        XCTAssertTrue(system!.contains("App-specific"))
        // General prompt must NOT leak in when general cleanup is off.
        XCTAssertFalse(system!.contains("FIX-PUNCTUATION"))
    }

    func testAssembleBoth() {
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "FIX-PUNCTUATION", profile: slack)
        XCTAssertNotNil(system)
        XCTAssertTrue(system!.contains("FIX-PUNCTUATION"))
        XCTAssertTrue(system!.contains(slack.instructions))
    }

    // MARK: - passesLengthGuard

    func testLengthGuardRejectsEmptyOutput() {
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(
            input: "This is a sentence long enough to be guarded.", output: ""))
    }

    func testLengthGuardRejectsWhitespaceOutput() {
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(
            input: "This is a sentence long enough to be guarded.", output: "   \n  "))
    }

    func testLengthGuardAllowsSimilarLength() {
        let input = "this is a sentence long enough to be guarded"
        let output = "This is a sentence long enough to be guarded."
        XCTAssertTrue(LLMPostProcessor.passesLengthGuard(input: input, output: output))
    }

    func testLengthGuardRejectsFiveXBlowup() {
        // Input is well over the 20-char short-input allowance, so the ratio check applies.
        let input = "send the report to the team please"   // 34 chars
        let output = String(repeating: "x", count: input.count * 5)
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(input: input, output: output))
    }

    func testLengthGuardAllowsTinyInputPassthrough() {
        // Input under 20 chars skips the ratio check, so even a large relative change passes.
        XCTAssertTrue(LLMPostProcessor.passesLengthGuard(input: "ok", output: "OK."))
    }

    func testLengthGuardRejectsHeavyShrinkWithoutProfile() {
        // Prose cleanup returns roughly the same text; a 0.2x collapse means the model
        // went off-contract, so the raw transcription wins.
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(
            input: "send the report to the team please", output: "sent it"))
    }

    func testLengthGuardAllowsCondensingWithProfile() {
        // The shipped Terminal preset's own examples condense hard — they must survive the
        // guard, or app-aware formatting silently does nothing.
        XCTAssertTrue(LLMPostProcessor.passesLengthGuard(
            input: "three zero zero zero", output: "3000", condensingAllowed: true))
        XCTAssertTrue(LLMPostProcessor.passesLengthGuard(
            input: "open paren close paren", output: "()", condensingAllowed: true))
        XCTAssertTrue(LLMPostProcessor.passesLengthGuard(
            input: "ENG dash one zero five one six", output: "ENG-10516", condensingAllowed: true))
    }

    func testLengthGuardStillRejectsCollapseToNothingWithProfile() {
        // A profile relaxes the floor, it doesn't remove it: a one-word reply to a long
        // dictation is still the model answering instead of transforming.
        let input = String(repeating: "convert this spoken text into symbols. ", count: 6)
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(
            input: input, output: "OK.", condensingAllowed: true))
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(
            input: input, output: "   ", condensingAllowed: true))
    }

    /// Stand-in for an external backend (Ollama / Remote), which must inherit the opt-out.
    private struct StubBackend: LLMCleanupBackend {
        var isReady = true
        func generate(system: String, user: String) async throws -> String { "" }
    }

    func testExternalBackendsOptOutOfRatioGuard() {
        // Only the small built-in model asks for the ratio check; external backends keep the
        // original blank-output-only behaviour, so a deliberately condensing custom instruction
        // on a big model isn't rejected.
        XCTAssertFalse(StubBackend().enforcesLengthRatio)
        XCTAssertTrue(BuiltInLlamaBackend.shared.enforcesLengthRatio)
    }

    func testLengthGuardStillRejectsBlowupWithProfile() {
        // The ceiling is unchanged by a profile — an explanation is an explanation.
        let input = "git checkout dash b feature slash login"
        XCTAssertFalse(LLMPostProcessor.passesLengthGuard(
            input: input, output: String(repeating: "x", count: input.count * 4),
            condensingAllowed: true))
    }

    // MARK: - the shipped instruction

    func testShippedClosingStatesTheOutputLanguage() {
        // Without a sentence about the output language, nothing in the prompt fixes it — which is
        // the bug this replaced. The wording travels with "Translate to …".
        XCTAssertTrue(LLMPostProcessor.defaultClosingInstruction
            .contains("Write your output in the same language as the transcription."))
    }

    func testShippedClosingEndsWithTheGuardrail() {
        // Closest to the text is where a weak model needs the reminder not to answer it.
        XCTAssertTrue(LLMPostProcessor.defaultClosingInstruction
            .contains("Output only the corrected text"))
    }

    // MARK: - passesTranslationGuard

    func testTranslationGuardAcceptsASimilarlyLongTranslation() {
        XCTAssertTrue(LLMPostProcessor.passesTranslationGuard(
            source: "Fix punctuation and capitalization. Output only the corrected text.",
            translated: "Korrigiere Zeichensetzung und Großschreibung. Gib nur den korrigierten Text aus."))
    }

    func testTranslationGuardRejectsAFragment() {
        // Observed with the built-in 1.5B model: it returned the placeholder alone and the app
        // swallowed a carefully written prompt.
        XCTAssertFalse(LLMPostProcessor.passesTranslationGuard(
            source: "Fix punctuation and capitalization. Output only the corrected text.",
            translated: "{{language}}"))
    }

    func testTranslationGuardRejectsEmptyOutput() {
        XCTAssertFalse(LLMPostProcessor.passesTranslationGuard(
            source: "Fix punctuation and capitalization.", translated: "   "))
    }

    func testTranslationGuardRejectsAnAnsweringModel() {
        let source = "Fix punctuation and capitalization. Output only the corrected text."
        XCTAssertFalse(LLMPostProcessor.passesTranslationGuard(
            source: source, translated: String(repeating: "x", count: source.count * 3)))
    }

    // MARK: - nothing wrapped around the instruction

    func testAssembleIsTheInstructionVerbatim() {
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "FIX-PUNCTUATION", profile: nil)
        XCTAssertEqual(system, "FIX-PUNCTUATION")
    }

    func testAssembleSandwichesAppRulesBetweenTheHalves() {
        // The whole point of splitting the instruction: an app rule appended behind the guardrail
        // would be the model's last word.
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPENING", profile: slack, closingPrompt: "CLOSING")
        XCTAssertEqual(system, """
            OPENING

            App-specific formatting rules:
            \(slack.instructions)

            CLOSING
            """)
    }

    func testAssembleWithoutProfileStillClosesLast() {
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPENING", profile: nil, closingPrompt: "CLOSING")
        XCTAssertEqual(system, "OPENING\n\nCLOSING")
    }

    func testAssembleDropsAnEmptyClosing() {
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPENING", profile: nil, closingPrompt: "  ")
        XCTAssertEqual(system, "OPENING")
    }

    func testAssembleOmitsClosingWhenGeneralCleanupIsOff() {
        // Closing belongs to the general instruction; with only app formatting on, the profile
        // rules are the whole prompt.
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: false, generalPrompt: "OPENING", profile: slack, closingPrompt: "CLOSING")
        XCTAssertEqual(system, "App-specific formatting rules:\n\(slack.instructions)")
    }

    func testAssembleDropsAnEmptyInstruction() {
        // Clearing the field is a supported choice, not an error to paper over.
        let system = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "   ", profile: slack)
        XCTAssertEqual(system, "App-specific formatting rules:\n\(slack.instructions)")
    }
}

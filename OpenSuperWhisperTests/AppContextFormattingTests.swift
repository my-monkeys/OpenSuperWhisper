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
}

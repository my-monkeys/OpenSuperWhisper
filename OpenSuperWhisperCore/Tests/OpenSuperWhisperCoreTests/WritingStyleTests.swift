import XCTest
@testable import OpenSuperWhisperCore

/// Writing styles in the cleanup prompt (#160): where a style's instructions go, when they are
/// left out, and which ones the echo guard knows as the app's own text.
final class WritingStyleTests: CoreTestCase {

    private let mail = AppContextProfile(bundleIdentifier: "com.apple.mail", appName: "Mail",
                                         instructions: "Mail rules.")

    private func prompt(general: Bool = true, style: String, profile: AppContextProfile? = nil) -> String? {
        LLMPostProcessor.assembleSystemPrompt(generalCleanup: general, generalPrompt: "Opening.",
                                              profile: profile, closingPrompt: "Closing.", style: style)
    }

    func testRawAddsNothing() {
        XCTAssertEqual(prompt(style: WritingStyle.raw.instructions), prompt(style: ""))
    }

    /// The style adjusts the general instruction, the app rules then the guardrail come after it.
    func testAStyleSitsBetweenTheOpeningAndTheAppRules() throws {
        let system = try XCTUnwrap(prompt(style: WritingStyle.pro.instructions, profile: mail))
        let opening = try XCTUnwrap(system.range(of: "Opening.")).lowerBound
        let style = try XCTUnwrap(system.range(of: WritingStyle.pro.instructions)).lowerBound
        let rules = try XCTUnwrap(system.range(of: "Mail rules.")).lowerBound
        let closing = try XCTUnwrap(system.range(of: "Closing.")).lowerBound
        XCTAssertLessThan(opening, style)
        XCTAssertLessThan(style, rules)
        XCTAssertLessThan(rules, closing)
    }

    /// A style is a way of cleaning up: with general cleanup off, app formatting alone runs and
    /// the style stays out.
    func testNoStyleWithoutGeneralCleanup() throws {
        let system = try XCTUnwrap(prompt(general: false, style: WritingStyle.pro.instructions, profile: mail))
        XCTAssertFalse(system.contains(WritingStyle.pro.instructions))
    }

    func testBuiltInStylesCountAsShippedTextAndCustomOnesDoNot() {
        func shipped(_ style: String) -> String {
            LLMPostProcessor.shippedInstructions(
                generalCleanup: true, generalPrompt: "", profile: nil, closingPrompt: "",
                translating: false, translationPrompt: "", style: style)
        }
        XCTAssertTrue(shipped(WritingStyle.personal.instructions).contains(WritingStyle.personal.instructions))
        XCTAssertFalse(shipped("Warm and encouraging.").contains("Warm and encouraging."))
    }

    func testAnUnknownStyleFallsBackToRaw() {
        let charity = WritingStyle(id: "c1", name: "Charity", instructions: "Warm.")
        XCTAssertEqual(WritingStyle.resolve("c1", custom: [charity]), charity)
        XCTAssertEqual(WritingStyle.resolve("deleted", custom: [charity]), .raw)
        XCTAssertEqual(WritingStyle.resolve(nil, custom: []), .raw)
    }
}

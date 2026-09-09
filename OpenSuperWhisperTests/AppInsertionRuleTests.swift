import XCTest

@testable import OpenSuperWhisper

/// Choosing how text reaches one particular app, and how fast.
///
/// From #85: typing posts a keyboard event per twenty characters, and an app that redraws its
/// whole input area per keystroke falls behind, losing part of the text or landing all of it at a
/// caret that has moved. Pasting is immune and costs the clipboard. Which of those is the worse
/// trade depends on the app and on the person, so it is a list.
final class AppInsertionRuleTests: XCTestCase {

    private let vsCode = AppInsertionRule(
        bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code",
        mode: .type, typingPaceMilliseconds: 12)
    private let terminal = AppInsertionRule(
        bundleIdentifier: "com.apple.Terminal", appName: "Terminal", mode: .paste)

    private var rules: [AppInsertionRule] { [vsCode, terminal] }

    // MARK: - Matching

    func testTheRuleForAnAppIsFound() {
        XCTAssertEqual(AppInsertionRule.rule(for: "com.apple.Terminal", in: rules), terminal)
    }

    /// A bundle identifier typed by hand rarely comes out capitalised the way the system reports
    /// it, and a rule that silently does not apply is worse than no rule at all.
    func testMatchingIgnoresCase() {
        XCTAssertEqual(AppInsertionRule.rule(for: "com.microsoft.vscode", in: rules), vsCode)
        XCTAssertEqual(AppInsertionRule.rule(for: "COM.APPLE.TERMINAL", in: rules), terminal)
    }

    /// No rule means the global setting decides, which is what every existing install gets.
    func testAnAppWithNoRuleMatchesNothing() {
        XCTAssertNil(AppInsertionRule.rule(for: "com.apple.Notes", in: rules))
        XCTAssertNil(AppInsertionRule.rule(for: nil, in: rules))
        XCTAssertNil(AppInsertionRule.rule(for: "", in: rules))
    }

    /// A half-filled row in the editor must not swallow every app that comes past it.
    func testARuleWithNoIdentifierNeverMatches() {
        let blank = AppInsertionRule(bundleIdentifier: "", appName: "", mode: .paste)

        XCTAssertNil(AppInsertionRule.rule(for: "com.apple.Notes", in: [blank]))
        XCTAssertEqual(AppInsertionRule.rule(for: "com.apple.Terminal", in: [blank, terminal]),
                       terminal)
    }

    /// Duplicates are the user's business, but the behaviour has to be the one the list reads.
    func testTheFirstMatchWins() {
        let second = AppInsertionRule(bundleIdentifier: "com.apple.Terminal",
                                      appName: "Terminal again", mode: .type)

        XCTAssertEqual(AppInsertionRule.rule(for: "com.apple.Terminal", in: [terminal, second]),
                       terminal)
    }

    // MARK: - Round trip

    /// The list lives in UserDefaults as JSON, so a rule has to survive encoding unchanged,
    /// including the optional pace that is the whole point of the typing case.
    func testARuleSurvivesEncoding() throws {
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([AppInsertionRule].self, from: data)

        XCTAssertEqual(decoded, rules)
        XCTAssertEqual(decoded.first?.typingPaceMilliseconds, 12)
        XCTAssertNil(decoded.last?.typingPaceMilliseconds)
    }

    // MARK: - The pace

    func testMillisecondsBecomeMicroseconds() {
        XCTAssertEqual(TextInserter.microseconds(fromMilliseconds: 2), 2_000)
        XCTAssertEqual(TextInserter.microseconds(fromMilliseconds: 12), 12_000)
    }

    /// Typing blocks the main thread, because the caller presses Return after it returns and going
    /// async would race the submit key against its own text. So a number typed into a settings
    /// field cannot be allowed to freeze the app.
    func testThePaceIsClamped() {
        XCTAssertEqual(TextInserter.microseconds(fromMilliseconds: -5), 0)
        XCTAssertEqual(TextInserter.microseconds(fromMilliseconds: 9_999),
                       useconds_t(TextInserter.maxChunkPauseMilliseconds) * 1_000)
    }

    /// A normal dictation gets the pace it asked for.
    func testAShortTextGetsTheFullPace() {
        XCTAssertEqual(TextInserter.chunkPause(forChunkCount: 6, requested: 12_000), 12_000)
    }

    /// And a very long one trades pacing for responsiveness rather than stalling the app, since
    /// the total is what blocks the main thread.
    func testAVeryLongTextIsCappedInTotal() {
        let chunks = 500
        let pause = TextInserter.chunkPause(forChunkCount: chunks, requested: 12_000)

        XCTAssertLessThan(pause, 12_000)
        XCTAssertLessThanOrEqual(UInt(pause) * UInt(chunks - 1),
                                 UInt(TextInserter.maxTotalPauseMicroseconds))
    }

    /// The higher the pace, the sooner the cap starts biting. Worth pinning: raising the dial must
    /// shorten the text at which it takes effect, not silently do nothing.
    func testARaisedPaceReachesTheCapSooner() {
        let chunks = 100
        let slow = TextInserter.chunkPause(forChunkCount: chunks, requested: 20_000)
        let quick = TextInserter.chunkPause(forChunkCount: chunks, requested: 2_000)

        XCTAssertEqual(quick, 2_000, "2ms over 100 chunks is well inside the total budget")
        XCTAssertLessThan(slow, 20_000, "20ms over 100 chunks is not")
    }

    func testNoPaceMeansNoWait() {
        XCTAssertEqual(TextInserter.chunkPause(forChunkCount: 10, requested: 0), 0)
        XCTAssertEqual(TextInserter.chunkPause(forChunkCount: 1, requested: 12_000), 0)
    }
}

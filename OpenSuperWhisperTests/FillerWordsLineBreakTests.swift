import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Filler-word removal runs after the engine has applied the custom dictionary, so it sees the
/// line breaks a "new paragraph" rule wrote. Tidying the spaces a removed filler leaves behind
/// used to collapse every run of whitespace, newlines included, which turned each paragraph
/// break into a space as soon as the option was on (#179).
final class FillerWordsLineBreakTests: XCTestCase {

    private var scratch: ScratchPreferences!

    override func setUp() {
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        scratch.restore()
    }

    private let newParagraph = CustomDictionaryEntry(original: "new paragraph", replacement: "\\n\\n")

    /// What the engine hands the app for this dictation: the dictionary already applied.
    private func dictated(_ text: String) -> String {
        CustomDictionary.apply(text, entries: [newParagraph])
    }

    /// The same text through `cleanTranscription`, with the stored default pattern.
    private func cleaned(_ text: String, fillers: Bool) -> String {
        AppPreferences.shared.removeFillerWords = fillers
        return AppPreferences.shared.cleanTranscription(text, language: "en")
    }

    // MARK: - the report

    func testDictionaryParagraphBreakSurvivesFillerRemoval() {
        let text = dictated("This is the first paragraph. new paragraph This is the second paragraph.")

        XCTAssertEqual(cleaned(text, fillers: true),
                       "This is the first paragraph.\n\nThis is the second paragraph.")
    }

    func testFillersOnKeepsTheLineBreaksOfFillersOff() {
        let inputs = [
            "First thought. new paragraph Second thought.",
            "Um, first thought. new paragraph uh second thought. new paragraph Third.",
            "So um new paragraph we start again",
            "The end. new paragraph",
        ]

        for input in inputs {
            let text = dictated(input)
            XCTAssertEqual(lineBreaks(in: cleaned(text, fillers: true)),
                           lineBreaks(in: cleaned(text, fillers: false)),
                           "for \(input.debugDescription)")
        }
    }

    func testTrailingParagraphBreakIsKept() {
        let text = dictated("The end um new paragraph")

        XCTAssertEqual(cleaned(text, fillers: false), "The end um\n\n")
        XCTAssertEqual(cleaned(text, fillers: true), "The end\n\n")
    }

    func testFillersAreStillRemovedAroundTheBreak() {
        let text = dictated("Um, first. new paragraph uh, second.")

        XCTAssertEqual(cleaned(text, fillers: true), "first.\n\nsecond.")
    }

    // MARK: - whatever the pattern

    /// The default pattern ends in `\s*`, so a filler right before a break used to take the
    /// break with it.
    func testDefaultPatternGivesBackTheNewlineItSwallowed() {
        let pattern = AppPreferences.shared.fillerWordsPattern

        XCTAssertEqual(AppPreferences.stripFillerWords("So um\n\nnext", pattern: pattern),
                       "So\n\nnext")
    }

    func testPatternEatingWhitespaceOnBothSidesKeepsTheBreak() {
        let pattern = "\\s*\\b(um|uh)\\b\\s*"

        XCTAssertEqual(AppPreferences.stripFillerWords("first.\n\num second", pattern: pattern),
                       "first.\n\nsecond")
        XCTAssertEqual(AppPreferences.stripFillerWords("first uh\nsecond", pattern: pattern),
                       "first\nsecond")
    }

    func testPatternThatNamesTheNewlineStillKeepsIt() {
        XCTAssertEqual(AppPreferences.stripFillerWords("one um\n\ntwo", pattern: "um\\n+"),
                       "one\n\ntwo")
    }

    func testFillerAtTheStartOfALineLeavesNoIndent() {
        XCTAssertEqual(AppPreferences.stripFillerWords("first.\num second", pattern: "\\bum\\b"),
                       "first.\nsecond")
    }

    // MARK: - the tidy-up

    func testOnlySpacesAndTabsAreCollapsed() {
        XCTAssertEqual(AppPreferences.stripFillerWords("a um  b\t\tc\n\n\nd", pattern: "\\bum\\b"),
                       "a b c\n\n\nd")
    }

    func testFillerAloneOnTheEdgesIsTrimmed() {
        XCTAssertEqual(AppPreferences.stripFillerWords("um hello uh", pattern: "\\b(um|uh)\\b"),
                       "hello")
    }

    func testInvalidPatternRemovesNothing() {
        XCTAssertEqual(AppPreferences.stripFillerWords("um\n\nhello", pattern: "(um"),
                       "um\n\nhello")
    }

    func testOffLeavesTheTextAlone() {
        XCTAssertEqual(cleaned("um  hello\n\n", fillers: false), "um  hello\n\n")
    }

    /// The shape of the text's lines: how many there are and which ones are blank. Two texts
    /// with the same shape break in the same places, whatever words were removed in between.
    private func lineBreaks(in text: String) -> [Bool] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(\.isEmpty)
    }
}

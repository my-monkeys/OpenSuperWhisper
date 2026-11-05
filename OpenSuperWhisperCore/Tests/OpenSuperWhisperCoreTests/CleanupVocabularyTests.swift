import XCTest
@testable import OpenSuperWhisperCore

/// The dictionary's terms in the cleanup prompt (#169), so the model keeps "Rsets" rather than
/// "fixing" it back into "resets".
final class CleanupVocabularyTests: CoreTestCase {

    private let slack = AppContextProfile(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack",
                                          instructions: "SLACK-RULES")

    func testNoTermsSendsThePromptUnchanged() {
        let without = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPEN", profile: slack, closingPrompt: "CLOSE")
        let empty = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPEN", profile: slack, closingPrompt: "CLOSE", vocabulary: [])
        XCTAssertEqual(without, empty)
        XCTAssertNil(LLMPostProcessor.vocabularySection([]))
    }

    func testTermsSitAfterTheOpeningAndBeforeTheAppRulesAndClosing() throws {
        let system = try XCTUnwrap(LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPEN", profile: slack, closingPrompt: "CLOSE",
            translating: true, translationPrompt: "TRANSLATED", vocabulary: ["Rsets", "OpenSuperWhisper"]))
        XCTAssertEqual(system, """
            OPEN

            TRANSLATED

            Keep these words spelled exactly as written here: Rsets, OpenSuperWhisper.

            App-specific formatting rules:
            SLACK-RULES

            CLOSE
            """)
    }

    func testTermsAloneDoNotStartAPass() {
        XCTAssertNil(LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: false, generalPrompt: "OPEN", profile: nil, vocabulary: ["Rsets"]))
    }

    func testOnlyTheTermsInTheTextAreSent() {
        let terms = ["Rsets", "OpenSuperWhisper", "camille@example.com", "Ångström"]
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(terms, in: "we tried rsets and angstrom units"),
                       ["Rsets", "Ångström"])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(terms, in: "nothing of the kind"), [])
    }

    func testOnlyWholeWordsCount() {
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Max"], in: "the maximum is ten"), [])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["AI"], in: "she said so"), [])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Max", "AI"], in: "ask Max about AI."), ["Max", "AI"])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Rsets"], in: "Rsets_v2 and xRsets"), [])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Rsets"], in: "(Rsets), «Rsets»"), ["Rsets"])
    }

    func testAccentsAndCaseAreIgnored() {
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Éloïse"], in: "merci eloise !"), ["Éloïse"])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Ångström"], in: "angstroms"), [])
    }

    func testMultiWordTerms() {
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["My Monkey"], in: "thanks to my\nmonkey team"), ["My Monkey"])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["My Monkey"], in: "my monkeys"), [])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["Claude Code"], in: "claude coded it"), [])
    }

    func testTermsWithPunctuation() {
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["C++", "Node.js", "camille@example.com"],
                                                          in: "I write C++ and node.js, mail camille@example.com."),
                       ["C++", "Node.js", "camille@example.com"])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["C++"], in: "C is fine"), [])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["camille@example.com"], in: "camille@example.community"), [])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(["a+b"], in: "x a+b y"), ["a+b"],
                       "regex characters in a term are taken literally")
    }

    func testTheListIsCut() throws {
        let terms = (1...60).map { "Term\($0)" }
        let section = try XCTUnwrap(LLMPostProcessor.vocabularySection(terms))
        XCTAssertTrue(section.contains("Term40."))
        XCTAssertFalse(section.contains("Term41"))
    }

    func testTheSectionIsPartOfWhatTheEchoGuardKnows() {
        let shipped = LLMPostProcessor.shippedInstructions(
            generalCleanup: true, generalPrompt: "custom", profile: nil, closingPrompt: "custom",
            translating: false, translationPrompt: "", vocabulary: ["Rsets"])
        XCTAssertEqual(shipped, "Keep these words spelled exactly as written here: Rsets.")
    }

    /// The section is built from the dictionary only while it is on, through `process`'s use of
    /// `cleanupTerms`: punctuation rules and regex templates never reach the model as words.
    func testOnlyRealTermsReachThePrompt() {
        let terms = CustomDictionary.cleanupTerms(entries: [
            CustomDictionaryEntry(original: "rsets", replacement: "Rsets"),
            CustomDictionaryEntry(original: "open quote", replacement: "“", spacing: .attachesRight),
            CustomDictionaryEntry(original: "(\\w+) said", replacement: "$1 said", isRegex: true),
        ])
        XCTAssertEqual(LLMPostProcessor.vocabularySection(terms),
                       "Keep these words spelled exactly as written here: Rsets.")
    }

    /// The recognition switch is about the speech engine: a word switched off there, the very
    /// one a cleanup model would otherwise "correct", still goes to the cleanup prompt.
    func testAWordKeptFromRecognitionStillReachesTheCleanup() {
        let entries = [CustomDictionaryEntry(original: "Maxime", replacement: "Maxim", boostsRecognition: false)]

        XCTAssertEqual(CustomDictionary.boostTerms(entries: entries), [])
        XCTAssertEqual(CustomDictionary.cleanupTerms(entries: entries), ["Maxim"])
    }

    /// A pattern that writes a plain word teaches the model that word; one that writes what it
    /// matched does not.
    func testAPatternWritingAWordReachesTheCleanup() {
        let entries = [
            CustomDictionaryEntry(original: "\\byou ?gardener\\b", replacement: "YouGardener", isRegex: true),
            CustomDictionaryEntry(original: "(\\w+) said", replacement: "$1 said", isRegex: true),
            CustomDictionaryEntry(original: "(\\w+) told", replacement: "\\1 told", isRegex: true),
        ]

        XCTAssertEqual(CustomDictionary.cleanupTerms(entries: entries), ["YouGardener"])
        XCTAssertEqual(CustomDictionary.spellings(entries: entries), [])
    }
}

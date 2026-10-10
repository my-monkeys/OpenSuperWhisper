import XCTest

@testable import OpenSuperWhisperCore

/// Dictionary rules that match with a regular expression and put capture groups back.
///
/// This exists so a one-person need does not become a one-person feature. A novelist dictating
/// fiction gets her words back with no quotation marks, because a quotation mark is not a sound,
/// and what she needs is one substitution: whatever precedes "said Frank" was spoken. Expressed
/// as a rule she can paste, it is also every rule nobody has asked for yet.
final class DictionaryRegexTests: CoreTestCase {

    /// The rule this was built for, verbatim.
    private func dialogueRule() -> CustomDictionaryEntry {
        CustomDictionaryEntry(
            original: "([^\\s.?!\"\\n][^.?!\"\\n]*)([,?!])\\s+(said|asked|inquired|suggested)\\s+([A-Z][\\p{L}'’-]*\\p{L})(?=\\s*[.,;:!?]|\\s*$)",
            replacement: "\"$1$2\" $3 $4",
            isRegex: true)
    }

    // MARK: - What it is for

    func testCaptureGroupsComeBackInTheResult() {
        let out = CustomDictionary.apply("Barbecuing is a man's job, said Frank.",
                                         entries: [dialogueRule()])

        XCTAssertEqual(out, "\"Barbecuing is a man's job,\" said Frank.")
    }

    func testTheQuestionMarkIsCarriedInside() {
        let out = CustomDictionary.apply("And the sausages? inquired Charity.",
                                         entries: [dialogueRule()])

        XCTAssertEqual(out, "\"And the sausages?\" inquired Charity.")
    }

    /// The whole passage the rule came from: no word may change.
    func testHerPassageKeepsEveryWord() {
        let heard = """
            And the sausages? inquired Charity. Barbecuing is a man's job, said Frank. \
            Timothy and Peter might be a good bet for that, suggested Charity, thinking that \
            those two gentlemen would probably be happy. Capital, capital, I'll ask them, said \
            Frank, rubbing his hands together with glee.
            """
        let out = CustomDictionary.apply(heard, entries: [dialogueRule()])

        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        XCTAssertEqual(words(out), words(heard))
        XCTAssertTrue(out.contains("\"Capital, capital, I'll ask them,\" said Frank"))
    }

    // MARK: - Literal rules must be unaffected

    /// Everything already in people's dictionaries is a literal rule, and regex metacharacters
    /// in it must keep being taken literally.
    func testALiteralRuleStillEscapesItsPattern() {
        let entry = CustomDictionaryEntry(original: "C++", replacement: "C plus plus")

        XCTAssertEqual(CustomDictionary.apply("I write C++ daily", entries: [entry]),
                       "I write C plus plus daily")
    }

    func testALiteralDollarSignIsNotATemplate() {
        let entry = CustomDictionaryEntry(original: "dollar one", replacement: "$1")

        XCTAssertEqual(CustomDictionary.apply("say dollar one here", entries: [entry]),
                       "say $1 here")
    }

    func testLiteralRulesKeepTheirWordBoundaries() {
        let entry = CustomDictionaryEntry(original: "cat", replacement: "dog")

        XCTAssertEqual(CustomDictionary.apply("category cat", entries: [entry]), "category dog")
    }

    // MARK: - Bad patterns must be harmless

    func testAPatternThatDoesNotCompileIsSkipped() {
        let entry = CustomDictionaryEntry(original: "([unclosed", replacement: "x", isRegex: true)

        XCTAssertEqual(CustomDictionary.apply("leave me alone", entries: [entry]),
                       "leave me alone")
    }

    /// Half-typed patterns are the normal state of the field while someone is writing one.
    func testAHalfTypedPatternDoesNotCorruptTheTranscription() {
        for partial in ["(", "([^", "([^.?!]+)(", "*", "?"] {
            let entry = CustomDictionaryEntry(original: partial, replacement: "\"$1\"",
                                              isRegex: true)
            let out = CustomDictionary.apply("Not tonight, said Frank.", entries: [entry])
            XCTAssertFalse(out.isEmpty, "\(partial) emptied the text")
        }
    }

    func testAnEmptyReplacementIsStillANoOp() {
        let entry = CustomDictionaryEntry(original: "(.+)", replacement: "", isRegex: true)

        XCTAssertEqual(CustomDictionary.apply("keep me", entries: [entry]), "keep me")
    }

    // MARK: - How it composes with the rest

    /// `spacing` is a second answer to a question the pattern already answers, so it is ignored.
    func testSpacingDoesNotApplyToARegexRule() {
        let entry = CustomDictionaryEntry(original: "yes", replacement: "no",
                                          spacing: .attachesRight, isRegex: true)

        XCTAssertEqual(CustomDictionary.apply("say yes now", entries: [entry]), "say no now")
    }

    /// A regex template is not a word, so it has nothing to teach the model in the prompt.
    func testRegexRulesAreNotBoostedIntoThePrompt() {
        let entries = [dialogueRule(),
                       CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]

        XCTAssertEqual(CustomDictionary.boostTerms(entries: entries), ["GitHub"])
    }

    /// Merging folds rules that write the same thing, and a regex writing "$1" is not the same
    /// rule as a literal one writing "$1".
    func testARegexRuleDoesNotMergeWithALiteralOne() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "a", replacement: "$1"),
            CustomDictionaryEntry(original: "b", replacement: "$1", isRegex: true),
        ])

        XCTAssertEqual(merged.count, 2)
    }

    func testSeveralPatternsCanReachOneResult() {
        let entry = CustomDictionaryEntry(original: "colou?r", replacement: "colour",
                                          alternates: ["couleur"], isRegex: true)

        XCTAssertEqual(CustomDictionary.apply("the color and the couleur", entries: [entry]),
                       "the colour and the colour")
    }

    // MARK: - Stored dictionaries

    /// Every dictionary saved before this field existed must still load, as a literal rule.
    func testOlderEntriesDecodeAsLiteral() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","original":"git hub","replacement":"GitHub"}]
        """
        let entries = try JSONDecoder().decode([CustomDictionaryEntry].self,
                                               from: Data(legacy.utf8))

        XCTAssertFalse(entries[0].isRegex, "an existing rule must not silently become a regex")
    }

    func testRoundTripsThroughCoding() throws {
        let entry = dialogueRule()
        let decoded = try JSONDecoder().decode(CustomDictionaryEntry.self,
                                               from: JSONEncoder().encode(entry))

        XCTAssertEqual(decoded, entry)
        XCTAssertTrue(decoded.isRegex)
    }
}

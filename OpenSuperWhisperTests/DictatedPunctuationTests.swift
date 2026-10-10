import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Dictionary rules that turn spoken punctuation into characters.
///
/// Swapping the words alone is not enough: "he said open quote hello close quote" becomes
/// `he said " hello "`, with the spaces that separated the words still sitting either side of
/// the mark. For someone dictating dialogue all day that is worse than the problem. A rule
/// therefore says which side its replacement glues to.
final class DictatedPunctuationTests: XCTestCase {

    private func openQuote() -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: "open quote", replacement: "\"",
                              alternates: ["opening quote", "quote unquote"],
                              spacing: .attachesRight)
    }

    private func closeQuote() -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: "close quote", replacement: "\"",
                              alternates: ["closing quote", "end quote"],
                              spacing: .attachesLeft)
    }

    // MARK: - Spacing

    func testQuotesGlueToTheWordsTheyBelongTo() {
        let text = CustomDictionary.apply("He said open quote hello close quote and left",
                                          entries: [openQuote(), closeQuote()])

        XCTAssertEqual(text, "He said \"hello\" and left")
    }

    func testStandaloneRulesKeepTheirSpacesAsBefore() {
        let entry = CustomDictionaryEntry(original: "git hub", replacement: "GitHub")
        XCTAssertEqual(CustomDictionary.apply("I pushed it to git hub today", entries: [entry]),
                       "I pushed it to GitHub today")
    }

    /// Only horizontal space is eaten. A rule must not pull two paragraphs together.
    func testDoesNotSwallowLineBreaks() {
        let text = CustomDictionary.apply("first line close quote\n\nsecond line",
                                          entries: [closeQuote()])
        XCTAssertEqual(text, "first line\"\n\nsecond line")
    }

    // MARK: - Several phrasings, one result

    func testAnyPhrasingProducesTheSameCharacter() {
        for spoken in ["open quote", "opening quote", "Open Quote"] {
            XCTAssertEqual(CustomDictionary.apply("she said \(spoken) yes", entries: [openQuote()]),
                           "she said \"yes",
                           "\(spoken) should reach the same mark")
        }
    }

    /// A longer phrasing must not be half-consumed by a shorter one on the same rule.
    func testLongestPhrasingWinsOverAShorterOne() {
        let entry = CustomDictionaryEntry(original: "quote", replacement: "\"",
                                          alternates: ["opening quote"],
                                          spacing: .attachesRight)

        XCTAssertEqual(CustomDictionary.apply("he said opening quote hi", entries: [entry]),
                       "he said \"hi")
    }

    // MARK: - Prompt boosting

    /// Punctuation replacements are not vocabulary; boosting a bare quote mark would only
    /// litter the initial prompt.
    func testPunctuationRulesAreNotBoostedIntoThePrompt() {
        let entries = [openQuote(), CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        XCTAssertEqual(CustomDictionary.boostTerms(entries: entries), ["GitHub"])
    }

    // MARK: - Stored dictionaries

    /// Dictionaries saved before these fields existed must still load. The synthesised decoder
    /// throws on missing keys, which would drop every rule the user had.
    func testOldEntriesStillDecode() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","original":"git hub","replacement":"GitHub"}]
        """
        let entries = try JSONDecoder().decode([CustomDictionaryEntry].self,
                                               from: Data(legacy.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].replacement, "GitHub")
        XCTAssertEqual(entries[0].spacing, .standalone, "old rules must not start eating spaces")
        XCTAssertTrue(entries[0].alternates.isEmpty)
    }

    func testRoundTripsThroughCoding() throws {
        let entry = openQuote()
        let decoded = try JSONDecoder().decode(CustomDictionaryEntry.self,
                                               from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
    }

    func testBlankAlternatesAreIgnored() {
        let entry = CustomDictionaryEntry(original: "hi", replacement: "Hi",
                                          alternates: ["", "   "])
        XCTAssertEqual(entry.triggers, ["hi"])
    }
}

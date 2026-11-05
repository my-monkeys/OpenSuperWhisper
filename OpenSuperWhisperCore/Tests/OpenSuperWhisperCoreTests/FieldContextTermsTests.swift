import XCTest
@testable import OpenSuperWhisperCore

/// Reducing the text already in the field to a vocabulary list (#89). The spelling dictionary is
/// a small made-up one, never `NSSpellChecker`: the real checker's verdict varies by OS version
/// and installed languages, so an assertion against it has an expected value nobody can state.
final class FieldContextTermsTests: CoreTestCase {

    /// Words a dictionary knows. Case-insensitive, as a real one is: it accepts "The" and "the".
    private static let known: Set<String> = [
        "the", "and", "is", "here", "met", "at", "about", "it", "run", "now", "call", "then",
        "again", "went", "sang", "repos", "code", "maxim", "parakeet", "charity", "bunny",
        "monday", "paris",
        "der", "mann", "ging", "zu", "hello", "there",
    ]

    private let spelling = DictionaryCandidates.Spelling(
        knows: { FieldContextTermsTests.known.contains($0.lowercased()) },
        correctsTypo: { _ in false })

    private func terms(_ text: String, limit: Int = 10) -> [String] {
        FieldContextTerms.terms(from: text, spelling: spelling, limit: limit)
    }

    // MARK: - Nothing to reduce

    func testEmptyWhitespaceAndPunctuationYieldNothing() {
        XCTAssertEqual(terms(""), [])
        XCTAssertEqual(terms("   \n\t "), [])
        XCTAssertEqual(terms("--- ... ,;:"), [])
        XCTAssertEqual(terms("() [] {}"), [])
    }

    func testNumeralsAreNotTerms() {
        XCTAssertEqual(terms("call 12345 now"), [])
    }

    func testCodeIsNotAFieldTerm() {
        XCTAssertEqual(terms("let x = foo.bar()"), [])
    }

    /// Scripts with no capitals carry no evidence this rule can read. Nothing, rather than
    /// something arbitrary.
    func testScriptsWithoutCapitalsYieldNothing() {
        XCTAssertEqual(terms("你好 世界"), [])
        XCTAssertEqual(terms("مرحبا بالعالم"), [])
    }

    // MARK: - What survives

    func testProseKeepsTheNamesInIt() {
        XCTAssertEqual(terms("I met Cherith at the Nyiragongo trail."),
                       ["Cherith", "Nyiragongo"])
    }

    /// A capital at the start of a sentence is grammar, and this word is known in lowercase.
    func testACommonWordThatWasCapitalisedIsNotATerm() {
        XCTAssertEqual(terms("the Parakeet sang"), [])
        XCTAssertEqual(terms("ask Maxim about it"), [])
    }

    /// The same two narrowings, on the words the plan names as deliberate exclusions: their
    /// lowercase forms are dictionary words.
    func testDictionaryWordsAreExcludedEvenWhenCapitalised() {
        XCTAssertEqual(terms("the Charity and the Bunny"), [])
    }

    /// Shape alone is evidence, so these survive even capitalised mid-sentence.
    func testStrongShapesSurvive() {
        XCTAssertEqual(terms("the GitHub, the OSW, and GPT4."), ["GitHub", "OSW", "GPT4"])
    }

    /// Lowercase unknown words are as likely a typo as jargon, so the field path does not boost
    /// them — unlike the dictionary-suggestion path, which follows a correction the user made.
    func testLowercaseUnknownIsNotATerm() {
        XCTAssertEqual(terms("run kubectl now"), [])
    }

    func testCyrillicKeepsItsShape() {
        XCTAssertEqual(terms("Привет мир"), ["Привет"])
    }

    // MARK: - Multi-word runs

    /// One row is not enough: this passes equally for an implementation with no run path at all,
    /// because per-word extraction also leaves "Claude".
    func testAMultiWordNameLosesItsCommonWord() {
        XCTAssertEqual(terms("Claude Code is here"), ["Claude"])
    }

    /// The companion row. Both words survive, joined — which is what discriminates a run from
    /// per-word extraction: per-word extraction would give two terms instead of one.
    func testAMultiWordNameKeepsWordsThatSurvive() {
        XCTAssertEqual(terms("Nyiragongo Cherith wrote"), ["Nyiragongo Cherith"])
    }

    // MARK: - Order, dedupe and the cap

    func testRepeatsDedupeCaseInsensitively() {
        XCTAssertEqual(terms("Nyiragongo then NYIRAGONGO again"), ["Nyiragongo"])
    }

    /// At 240 characters the cap is the ordinary path. Which ten survive is part of the answer:
    /// first occurrence in the text, left to right.
    func testTheCapKeepsTheFirstTenInTextOrder() {
        let many = ["Cherith", "Nyiragongo", "Sintra", "Dunlap", "Bennet",
                    "Kai", "Zed", "Tam", "Nix", "Obo", "Vex"]
        let reduced = terms(many.joined(separator: " and "))

        XCTAssertEqual(reduced.count, 10)
        XCTAssertEqual(reduced, Array(many.prefix(10)))
        XCTAssertFalse(reduced.contains("Vex"))
    }

    func testTheLimitIsTheCallers() {
        XCTAssertEqual(terms("Cherith and Nyiragongo and Sintra", limit: 2),
                       ["Cherith", "Nyiragongo"])
        XCTAssertEqual(terms("Cherith and Nyiragongo", limit: 0), [])
    }

    /// A document can hand this a single enormous token. It is not a term, and reducing it must
    /// not be quadratic.
    func testASingleVeryLongTokenYieldsNothing() {
        XCTAssertEqual(terms(String(repeating: "A", count: 10_000)), [])
    }

    /// Running the reducer over its own output changes nothing, which is what makes the cap's
    /// "first ten" stable rather than order-dependent.
    func testTheReductionIsIdempotent() {
        for text in ["Claude Code is here", "Nyiragongo Cherith wrote"] {
            let once = terms(text)
            XCTAssertFalse(once.isEmpty, text)
            XCTAssertEqual(terms(once.joined(separator: " ")), once, text)
        }
    }

    // MARK: - Languages that capitalise every noun

    /// German's mid-sentence capitals are grammar. The common nouns must not become terms; the
    /// surname still does.
    ///
    /// The guard is what rejects the nouns, not a language flag: a German noun is a known word in
    /// lowercase, so its capital buys it nothing.
    func testGermanNounsAreNotTerms() {
        XCTAssertEqual(terms("Der Mann ging zu Cherith"), ["Cherith"])
    }
}

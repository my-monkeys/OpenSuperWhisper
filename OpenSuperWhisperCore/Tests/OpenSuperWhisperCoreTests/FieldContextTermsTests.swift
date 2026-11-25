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
        "monday", "paris", "github", "bay", "pdf", "usa",
        "der", "mann", "ging", "zu", "hello", "there",
    ]

    private let spelling = DictionaryCandidates.Spelling(
        knows: { FieldContextTermsTests.known.contains($0.lowercased()) },
        correctsTypo: { _ in false })

    /// The same dictionary, with "github" unknown.
    ///
    /// The shared stub knows "github", so "GitHub" is dropped by the strong-shape rule; only a
    /// dictionary that does not know it lets the shape argument be tested at all. One word, two
    /// rows, two stub answers: `testStrongShapesSurvive` needs this one, and
    /// `testStrongShapesTheDictionaryKnowsAreDropped` pins the other. Each row keeps its own
    /// assertion rather than either being weakened to fit a shared stub.
    private let spellingWithoutGitHub = DictionaryCandidates.Spelling(
        knows: { $0.lowercased() != "github" && FieldContextTermsTests.known.contains($0.lowercased()) },
        correctsTypo: { _ in false })

    private func terms(_ text: String, capitalMarksNames: Bool = true, limit: Int = 10) -> [String] {
        FieldContextTerms.terms(from: text, spelling: spelling,
                                capitalMarksNames: capitalMarksNames, limit: limit)
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
    ///
    /// Its own stub, because the shared one knows "github" for the candidacy row below — see
    /// `spellingWithoutGitHub`.
    func testStrongShapesSurvive() {
        XCTAssertEqual(FieldContextTerms.terms(from: "the GitHub, the OSW, and GPT4.",
                                               spelling: spellingWithoutGitHub,
                                               capitalMarksNames: true),
                       ["GitHub", "OSW", "GPT4"])
    }

    /// The dictionary's own words are not boosted, even with a strong shape and even beside a
    /// real name — the reported "PDF"/"USA" over-boost.
    ///
    /// The cost, stated: an acronym or brand the OS dictionary knows as written loses its boost
    /// ("GitHub" here; "iOS" on a machine whose dictionary knows it). The model already spells
    /// those words, and the user's dictionary is the escape hatch for the rest.
    func testStrongShapesTheDictionaryKnowsAreDropped() {
        XCTAssertEqual(terms("the PDF Cherith wrote"), ["Cherith"])
        XCTAssertEqual(terms("the USA Nyiragongo wrote"), ["Nyiragongo"])
        XCTAssertEqual(terms("the GitHub Cherith wrote"), ["Cherith"])
    }

    /// Lowercase unknown words are as likely a typo as jargon, so the field path does not boost
    /// them — unlike the dictionary-suggestion path, which follows a correction the user made.
    func testLowercaseUnknownIsNotATerm() {
        XCTAssertEqual(terms("run kubectl now"), [])
    }

    /// A name can start lowercase and still be a name: the inner capital is the evidence, and it
    /// is exactly the shape of the product names this feature exists for. The door that stays
    /// shut is the one above — lowercase *without* shape is still dropped, which the assertion
    /// on "kubectl" pins from the other side.
    func testLowercaseInitialStrongShapesSurvive() {
        XCTAssertEqual(terms("I opened iOS and macOS in eBay"), ["iOS", "macOS", "eBay"])
    }

    /// Two sentences, two names. A run that crossed the full stop would invent "Cherith
    /// Nyiragongo" — a term the user never wrote — and swallow the second name into it.
    func testARunDoesNotCrossASentenceBoundary() {
        XCTAssertEqual(terms("I emailed Cherith. Nyiragongo was next."),
                       ["Cherith", "Nyiragongo"])
    }

    // MARK: - What ends a run
    //
    // Mutations these rows pin, each measured against a model of the reducer: drop the `endsRun`
    // barrier and the comma row fuses to "Cherith Nyiragongo Sintra" and the semicolon row to
    // "Cherith Nyiragongo"; drop the `startsSentence` check (or the gap from the flag) and the
    // one-per-line row fuses; revert to the old private tokenizer — no barrier and `. ! ?` as
    // the only sentence marks — and the ellipsis/CJK row fuses; replace the contiguous survivor
    // slice with "join every survivor" and the dropped-middle-word row emits "Cherith
    // Nyiragongo"; return `true` for a strong shape before asking the dictionary and the PDF/USA
    // row emits "PDF Cherith"; drop the memo and the lookup-count row goes from 3 to 36.

    /// A comma separates list items. The old tokenizer trimmed the comma and fused them.
    func testCommasSeparateNames() {
        XCTAssertEqual(terms("Cherith, Nyiragongo, Sintra"),
                       ["Cherith", "Nyiragongo", "Sintra"])
    }

    /// A semicolon or a colon separates just as a comma does.
    func testSemicolonsAndColonsSeparateNames() {
        XCTAssertEqual(terms("Cherith; Nyiragongo: Sintra"),
                       ["Cherith", "Nyiragongo", "Sintra"])
    }

    /// One name per line. The line break lives in the gap between tokens, which the whitespace
    /// split discards; the sentence flag has to see it or the lines fuse.
    func testLineBreaksSeparateNames() {
        XCTAssertEqual(terms("Cherith\nNyiragongo\nSintra"),
                       ["Cherith", "Nyiragongo", "Sintra"])
    }

    /// Sentence marks the private tokenizer did not know. Both are punctuation the shared
    /// `CorrectionDiff` already understands.
    func testEllipsisAndCJKFullStopEndRuns() {
        XCTAssertEqual(terms("Cherith… Nyiragongo。 Sintra"),
                       ["Cherith", "Nyiragongo", "Sintra"])
    }

    /// Only punctuation trimmed from a word's END is a barrier. A bracket or a quote in front of
    /// a name is punctuation of the sentence, not a separator inside it.
    func testLeadingPunctuationDoesNotBreakARun() {
        XCTAssertEqual(terms("(Nyiragongo Cherith) wrote"), ["Nyiragongo Cherith"])
        XCTAssertEqual(terms("\"Nyiragongo Cherith\" wrote"), ["Nyiragongo Cherith"])
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

    /// A word dropped from the middle ends the run. Joining across it would invent "Cherith
    /// Nyiragongo", a term the user never wrote, and swallow the second name doing it.
    ///
    /// "Bay" is dictionary-known, which is the evidence that drops it.
    func testADroppedMiddleWordEndsTheRun() {
        XCTAssertEqual(terms("Cherith Bay Nyiragongo wrote"),
                       ["Cherith", "Nyiragongo"])
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
    func testGermanNounsAreNotTerms() {
        XCTAssertEqual(terms("Der Mann ging zu Cherith", capitalMarksNames: false), ["Cherith"])
    }

    /// The flag no longer changes what the reducer emits.
    ///
    /// Its old row relied on "GitHub" being known as written: the run "Der Mann GitHub" was
    /// witnessed only by the flag's known-capital branch. Strong shapes are now held to the
    /// dictionary as well, so that witness is dropped by the guard, and every word that survives
    /// is vocabulary on its own. Fusion is what remains: two adjacent survivors become one term
    /// under either flag setting. (The witness path is unreachable with the `correctsTypo: false`
    /// stub, so no row can pin it; the recall the strong-shape rule costs is stated in
    /// `testStrongShapesTheDictionaryKnowsAreDropped`.)
    func testCapitalMarksNamesNoLongerChangesWhatSurvives() {
        XCTAssertEqual(terms("Sintra Dunlap wrote"), ["Sintra Dunlap"])
        XCTAssertEqual(terms("Sintra Dunlap wrote", capitalMarksNames: false), ["Sintra Dunlap"])
    }

    // MARK: - Lookup cost

    /// One lookup per distinct form, not one per run a word could start.
    ///
    /// This text offers each name as the start of up to three runs, and `isVocabulary` asks
    /// again inside each: the memo answers 3 lookups where the same text without it asks 36.
    /// The bound leaves room for a form asked in both cases without letting the memo disappear.
    func testSpellingIsAskedOncePerDistinctForm() {
        var asked: [String] = []
        let counting = DictionaryCandidates.Spelling(
            knows: { word in
                asked.append(word)
                return FieldContextTermsTests.known.contains(word.lowercased())
            },
            correctsTypo: { _ in false })
        let text = Array(repeating: "Nyiragongo Cherith", count: 12).joined(separator: " and ")

        XCTAssertEqual(FieldContextTerms.terms(from: text, spelling: counting,
                                               capitalMarksNames: true),
                       ["Nyiragongo Cherith"])
        XCTAssertLessThanOrEqual(asked.count, 8, "spelling asked \(asked.count) times: \(asked)")
    }
}

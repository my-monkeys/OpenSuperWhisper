import XCTest
@testable import OpenSuperWhisper

/// `parseStopPhrase` decides both when a take ends (on the live caption) and what is dropped
/// from the inserted text (#145). A false match ends someone's dictation mid-thought, so the
/// anchoring and word-boundary cases are covered here.
final class StopPhraseTests: XCTestCase {

    private func parse(_ s: String, _ phrase: String = "over and out") -> (text: String, matched: Bool) {
        AppPreferences.parseStopPhrase(s, phrase: phrase)
    }

    func testStripsTrailingPhrase() {
        let r = parse("Ship the build tonight over and out")
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.text, "Ship the build tonight")
    }

    func testCaseAndPunctuationAsTheModelWritesIt() {
        // Parakeet capitalizes and punctuates: "…tonight. Over and out."
        let r = parse("Ship the build tonight. Over, and out.")
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.text, "Ship the build tonight.")
    }

    func testPhraseAloneLeavesNothing() {
        let r = parse("Over and out.")
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.text, "")
    }

    func testPhraseMidSentenceDoesNotMatch() {
        // Said earlier in the take, it is content; only the last words end a recording.
        XCTAssertFalse(parse("He said over and out and hung up").matched)
    }

    func testPhraseMustStartAWord() {
        XCTAssertFalse(parse("cured my hangover and out", "over and out").matched)
    }

    func testPhraseWithPunctuationInTheSetting() {
        let r = parse("Done for today, stop dictation", "Stop, dictation!")
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.text, "Done for today")
    }

    func testRegexCharactersInThePhraseAreLiteral() {
        XCTAssertFalse(parse("anything at all", "a.*").matched)
    }

    func testEmptyPhraseIsOff() {
        let r = parse("over and out", "  ")
        XCTAssertFalse(r.matched)
        XCTAssertEqual(r.text, "over and out")
    }

    func testAccentedPhrase() {
        let r = parse("On s'arrête là. Fin de dictée.", "fin de dictée")
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.text, "On s'arrête là.")
    }
}

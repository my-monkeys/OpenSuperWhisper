import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// A new entry starts with "Also help recognition of this word" on for a New word and off for
/// every other kind, since a correction's rule already writes its replacement and boosting that
/// replacement made Parakeet hear "Maxim" for "Mais" (#234).
final class DictionaryNewEntryBoostTests: XCTestCase {

    func testOnlyAWordStartsBoosted() {
        XCTAssertTrue(DictionaryEntryKind.word.boostsByDefault)
        XCTAssertFalse(DictionaryEntryKind.correction.boostsByDefault)
        XCTAssertFalse(DictionaryEntryKind.command.boostsByDefault)
        XCTAssertFalse(DictionaryEntryKind.pattern.boostsByDefault)
    }

    func testAnEntryTakesItsDefaultFromItsKind() {
        let entries = [
            CustomDictionaryEntry(original: "Rsets", replacement: "Rsets"),
            CustomDictionaryEntry(original: "Maxime", replacement: "Maxim"),
            CustomDictionaryEntry(original: "new paragraph", replacement: "\\n\\n"),
            CustomDictionaryEntry(original: "(a), said (b)", replacement: "“$1” said $2", isRegex: true),
        ]
        XCTAssertEqual(entries.map { $0.withDefaultBoost().boostsRecognition }, [true, false, false, false])
    }

    // MARK: - Suggestions

    func testASuggestedNewWordIsBoosted() {
        let entry = DictionarySuggestion(term: "Kubernetes", heard: "kubernetes").entry
        XCTAssertEqual(entry.kind, .word)
        XCTAssertTrue(entry.boostsRecognition)
    }

    func testASuggestedCorrectionIsNot() {
        let entry = DictionarySuggestion(term: "Kubernetes", heard: "cooper netties").entry
        XCTAssertEqual(entry.kind, .correction)
        XCTAssertFalse(entry.boostsRecognition)
    }

    // MARK: - The editor's draft

    func testTheEditorStartsAWordBoostedOnceItHasOne() {
        let word = CustomDictionaryEntry(original: "Rsets", replacement: "Rsets")
        XCTAssertTrue(DictionaryEntryEditor.startsBoosted(word, asWord: true))
        XCTAssertTrue(DictionaryEntryEditor.startsBoosted(CustomDictionaryEntry(), asWord: true),
                      "an empty New word is still a word")
    }

    func testTheEditorStartsACorrectionOffWhateverItHolds() {
        XCTAssertFalse(DictionaryEntryEditor.startsBoosted(CustomDictionaryEntry(), asWord: false),
                       "an empty rule reads as a word but the card says Correction")
        XCTAssertFalse(DictionaryEntryEditor.startsBoosted(
            CustomDictionaryEntry(original: "Maxime", replacement: "Maxim"), asWord: false))
        XCTAssertFalse(DictionaryEntryEditor.startsBoosted(
            CustomDictionaryEntry(original: "a", replacement: "b", isRegex: true), asWord: false))
    }

    func testTheEditorFollowsTheKindAsTheUserTypes() {
        XCTAssertFalse(DictionaryEntryEditor.startsBoosted(
            CustomDictionaryEntry(original: "paragraph", replacement: "\\n"), asWord: true),
                       "a New word holding a line break is a Command")
    }
}

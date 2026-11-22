import CryptoKit
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The words offered for the dictionary from the corrections made after a dictation (#169): what
/// is offered, what an answer does, and that a refused or deleted word never comes back.
@MainActor
final class DictionarySuggestionsTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences(keychainAccounts: [DictionarySuggestions.refusalKeyAccount])
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    private func candidate(_ term: String, heard: String = "heard") -> DictionaryCandidates.Candidate {
        .init(term: term, heard: heard)
    }

    func testOffersNewWordsInOrder() {
        let store = DictionarySuggestions(prefs: prefs)
        let added = store.offer([candidate("Rsets", heard: "rest sets"), candidate("GitHub")])
        XCTAssertEqual(added.map(\.term), ["Rsets", "GitHub"])
        XCTAssertEqual(store.pending, added)
        XCTAssertEqual(added.first?.heard, "rest sets")
    }

    func testAPendingWordIsNotOfferedTwice() {
        let store = DictionarySuggestions(prefs: prefs)
        store.offer([candidate("Rsets")])
        XCTAssertEqual(store.offer([candidate("rsets"), candidate("Rsets")]), [])
        XCTAssertEqual(store.pending.count, 1)
    }

    func testAWordAlreadyInTheDictionaryIsNotOffered() {
        prefs.customDictionaryEntries = [
            CustomDictionaryEntry(original: "rest sets", replacement: "Rsets"),
            CustomDictionaryEntry(original: "cooper netties", replacement: "Kubernetes", alternates: ["GitHub"]),
        ]
        let store = DictionarySuggestions(prefs: prefs)
        XCTAssertEqual(store.offer([candidate("RSETS"), candidate("github"), candidate("Parakeet")]).map(\.term),
                       ["Parakeet"])
    }

    /// What was heard becomes the correction's trigger, so the next dictation writes the term.
    func testAddTurnsWhatWasHeardIntoTheTerm() throws {
        let store = DictionarySuggestions(prefs: prefs)
        let suggestion = try XCTUnwrap(store.offer([candidate("Maxim", heard: "Maxime")]).first)
        let changed = expectation(forNotification: .customDictionaryDidChange, object: nil)
        store.accept(suggestion)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.pending, [])
        let entry = try XCTUnwrap(prefs.customDictionaryEntries.first)
        XCTAssertEqual(entry.original, "Maxime")
        XCTAssertEqual(entry.replacement, "Maxim")
        XCTAssertEqual(entry.kind, .correction)
        XCTAssertEqual(CustomDictionary.apply("Merci Maxime !", entries: prefs.customDictionaryEntries),
                       "Merci Maxim !")
        XCTAssertEqual(CustomDictionary.boostTerms(entries: prefs.customDictionaryEntries), [],
                       "a correction starts outside recognition: its rule already writes the term")
    }

    /// Only the case was wrong: the term alone, which fixes its case wherever it is written.
    func testAddKeepsAWordWhenOnlyTheCaseDiffered() throws {
        let store = DictionarySuggestions(prefs: prefs)
        store.accept(try XCTUnwrap(store.offer([candidate("GitHub", heard: "github")]).first))
        let entry = try XCTUnwrap(prefs.customDictionaryEntries.first)
        XCTAssertEqual(entry.original, "GitHub")
        XCTAssertEqual(entry.kind, .word, "a term, not a replacement rule")
    }

    func testAddTwiceAddsOnce() throws {
        let store = DictionarySuggestions(prefs: prefs)
        let suggestion = try XCTUnwrap(store.offer([candidate("Rsets")]).first)
        store.accept(suggestion)
        store.accept(suggestion)
        XCTAssertEqual(prefs.customDictionaryEntries.count, 1)
    }

    func testARefusedWordIsNeverOfferedAgainInAnyCase() throws {
        let store = DictionarySuggestions(prefs: prefs)
        store.refuse(try XCTUnwrap(store.offer([candidate("Rsets")]).first))
        XCTAssertEqual(store.pending, [])
        XCTAssertEqual(prefs.customDictionaryEntries, [])
        XCTAssertEqual(store.offer([candidate("Rsets"), candidate("RSETS"), candidate("rsets")]), [])
        // Nor after a restart.
        XCTAssertEqual(DictionarySuggestions(prefs: prefs).offer([candidate("Rsets")]), [])
    }

    func testARefusedWordIsNotKeptAsText() throws {
        let store = DictionarySuggestions(prefs: prefs)
        store.refuse(try XCTUnwrap(store.offer([candidate("camille@example.com")]).first))
        XCTAssertEqual(prefs.dictionaryRefusedWords.count, 1)
        XCTAssertFalse(prefs.dictionaryRefusedWords.contains { $0.contains("camille") })
        XCTAssertEqual(prefs.dictionaryRefusedWords, [store.digest("CAMILLE@example.com")])
        // Keyed: not the plain hash a word list would undo.
        let plain = SHA256.hash(data: Data("camille@example.com".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(prefs.dictionaryRefusedWords.first, plain)
    }

    func testTheKeyOutlivesTheStore() throws {
        let store = DictionarySuggestions(prefs: prefs)
        store.refuse(try XCTUnwrap(store.offer([candidate("Rsets")]).first))
        XCTAssertEqual(DictionarySuggestions(prefs: prefs).digest("rsets"), store.digest("Rsets"))
        XCTAssertNotNil(Keychain.read(DictionarySuggestions.refusalKeyAccount))
    }

    func testClearingDropsThePendingWords() {
        let store = DictionarySuggestions(prefs: prefs)
        store.offer([candidate("Rsets")])
        store.clearPending()
        XCTAssertEqual(store.pending, [])
        XCTAssertNil(prefs.dictionarySuggestionsData)
    }

    func testADeletedWordIsNeverOfferedAgain() throws {
        let store = DictionarySuggestions(prefs: prefs)
        store.accept(try XCTUnwrap(store.offer([candidate("Rsets")]).first))
        let entry = try XCTUnwrap(prefs.customDictionaryEntries.first)
        prefs.customDictionaryEntries = []
        store.noteDeleted(entry)
        XCTAssertEqual(store.offer([candidate("Rsets")]), [])
    }

    func testDeletingAPunctuationOrPatternRuleRefusesNothing() {
        let store = DictionarySuggestions(prefs: prefs)
        store.noteDeleted(CustomDictionaryEntry(original: "open quote", replacement: "“"))
        store.noteDeleted(CustomDictionaryEntry(original: "(\\w+)", replacement: "$1", isRegex: true))
        XCTAssertEqual(prefs.dictionaryRefusedWords, [])
    }

    func testPendingSurvivesARestartAndIsCapped() {
        let store = DictionarySuggestions(prefs: prefs)
        for index in 1...(DictionarySuggestions.maxPending + 5) {
            store.offer([candidate("Term\(index)")])
        }
        let reloaded = DictionarySuggestions(prefs: prefs)
        XCTAssertEqual(reloaded.pending.count, DictionarySuggestions.maxPending)
        XCTAssertEqual(reloaded.pending.first?.term, "Term6", "the oldest go first")
        XCTAssertEqual(reloaded.pending.last?.term, "Term\(DictionarySuggestions.maxPending + 5)")
    }

    func testAnsweringTheLastOneClearsTheStoredList() throws {
        let store = DictionarySuggestions(prefs: prefs)
        store.refuse(try XCTUnwrap(store.offer([candidate("Rsets")]).first))
        XCTAssertNil(prefs.dictionarySuggestionsData)
    }
}

/// The course of one watch over its field (#169), with made-up reads: no field is read.
final class CorrectionTrailTests: XCTestCase {

    private let spelling = DictionaryCandidates.Spelling(
        knows: { ["we", "should", "try", "today", "the", "great", "greatest", "idea"].contains($0.lowercased()) },
        correctsTypo: { _ in false })

    /// "Notes: " then the dictation, in a field read whole.
    private func trail(_ dictated: String = "we should try rest sets today.",
                       before: String = "Notes: ", after: String = "") throws -> CorrectionTrail {
        let window = before + dictated + after
        let caret = ((before + dictated) as NSString).length
        return try XCTUnwrap(CorrectionTrail(dictated: dictated, window: window, windowStart: 0, caret: caret))
    }

    func testFindsTheDictationAtTheCaret() throws {
        let trail = try trail()
        XCTAssertEqual(trail.dictated, "we should try rest sets today.")
        XCTAssertEqual(trail.start, 7)
        XCTAssertTrue(trail.startsSentence, "a colon counts as a sentence end")
    }

    func testNothingWhenTheDictationIsNotInTheField() {
        XCTAssertNil(CorrectionTrail(dictated: "rest sets", window: "unrelated text", windowStart: 0, caret: 14))
    }

    func testFindsItInAWindowThatStartsLater() throws {
        let trail = try XCTUnwrap(CorrectionTrail(dictated: "rest sets", window: "the rest sets",
                                                  windowStart: 1_000, caret: 1_013))
        XCTAssertEqual(trail.start, 1_004)
        XCTAssertFalse(trail.startsSentence)
    }

    func testKeepsWatchingThroughEdits() throws {
        var trail = try trail()
        XCTAssertEqual(trail.read("Notes: we should try Rsets today.", windowStart: 0), .watching)
        XCTAssertEqual(trail.latest, "we should try Rsets today.")
    }

    func testFollowsTheDictationWhenTextIsTypedBeforeIt() throws {
        var trail = try trail()
        XCTAssertEqual(trail.read("A new line.\nNotes: we should try Rsets today.", windowStart: 0), .watching)
        XCTAssertEqual(trail.start, 19)
    }

    func testASentMessageEndsOnTheLastStateSeen() throws {
        var trail = try trail(before: "")
        XCTAssertEqual(trail.read("we should try Rsets today.", windowStart: 0), .watching)
        XCTAssertEqual(trail.read("", windowStart: 0), .done("we should try Rsets today."))
    }

    func testAFieldThatStopsAnsweringEndsOnTheLastStateSeen() throws {
        var trail = try trail()
        XCTAssertEqual(trail.read("Notes: we should try Rsets today.", windowStart: 0), .watching)
        XCTAssertEqual(trail.read(nil, windowStart: 0), .done("we should try Rsets today."))
    }

    func testReturnEndsOnTheTextBeforeIt() throws {
        var trail = try trail()
        XCTAssertEqual(trail.read("Notes: we should try Rsets today.\nAnd then", windowStart: 0),
                       .done("we should try Rsets today."))
    }

    func testTheNextWindowCoversTheDictationAndItsContext() throws {
        let trail = try trail(before: String(repeating: "x", count: 1_000) + " ", after: " tail")
        let window = try XCTUnwrap(trail.window(fieldLength: 5_000))
        XCTAssertEqual(window.location, 1_001 - CorrectionTrail.margin)
        XCTAssertEqual(NSMaxRange(window), 1_001 + trail.maxRegionLength + CorrectionTrail.margin)
    }

    func testNoWindowAtTheEndOfAHugeDocument() throws {
        let trail = try trail(before: "", after: "")
        XCTAssertNil(trail.window(fieldLength: WatchedField.maxWholeValue + 1))
        XCTAssertEqual(trail.window(fieldLength: 300), NSRange(location: 0, length: 300))
    }

    func testTheLandingWindowEndsPastTheCaret() {
        XCTAssertEqual(CorrectionTrail.landingWindow(caret: 1_000, dictatedLength: 100, fieldLength: 5_000),
                       NSRange(location: 300, length: 1_300))
        XCTAssertEqual(CorrectionTrail.landingWindow(caret: 10, dictatedLength: 10, fieldLength: 12),
                       NSRange(location: 0, length: 12))
    }

    func testTheCorrectionBecomesACandidate() throws {
        var trail = try trail()
        XCTAssertEqual(trail.read("Notes: we should try Rsets today.", windowStart: 0), .watching)
        XCTAssertEqual(trail.candidates(edited: trail.latest, spelling: spelling, capitalMarksNames: true),
                       [.init(term: "Rsets", heard: "rest sets")])
    }

    func testAnUntouchedDictationOffersNothing() throws {
        let trail = try trail()
        XCTAssertEqual(trail.candidates(edited: trail.latest, spelling: spelling, capitalMarksNames: true), [])
    }

    func testACommonWordFixedOffersNothing() throws {
        let trail = try trail("the great idea")
        XCTAssertEqual(trail.candidates(edited: "the greatest idea", spelling: spelling, capitalMarksNames: true), [])
    }

    /// The owner's own run in Notes: the dictation ends the note with a trailing space, he fixes
    /// "rest set" into "Rsets", then presses Return. The watch used to cut the dictation at its
    /// first space and saw "On", so nothing was offered.
    func testAFixAtTheEndOfANoteThenReturnIsOffered() throws {
        let pasted = "On se retrouve demain avec un rest set pour le point. "
        var trail = try XCTUnwrap(CorrectionTrail(dictated: pasted, window: pasted, windowStart: 0,
                                                  caret: (pasted as NSString).length))
        XCTAssertEqual(trail.read("On se retrouve demain avec un Rsets pour le point. ", windowStart: 0), .watching)
        guard case .done(let final) = trail.read("On se retrouve demain avec un Rsets pour le point. \n",
                                                 windowStart: 0) else { return XCTFail("Return ends the watch") }
        XCTAssertEqual(final, "On se retrouve demain avec un Rsets pour le point. ")
        let french = DictionaryCandidates.Spelling(
            knows: { ["on", "se", "retrouve", "demain", "avec", "un", "pour", "le", "point", "rest", "set"]
                .contains($0.lowercased()) },
            correctsTypo: { _ in false })
        XCTAssertEqual(trail.candidates(edited: final, spelling: french, capitalMarksNames: true).map(\.term), ["Rsets"])
    }
}

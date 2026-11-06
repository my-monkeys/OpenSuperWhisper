import XCTest
@testable import OpenSuperWhisperCore

/// Snippet triggers join the words recognition is biased toward, so a trigger is heard word for
/// word in the first place (#167), and snippets persist in a format that survives change.
final class SnippetBoostTests: CoreTestCase {

    private let email = Snippet(trigger: "my email", expansion: "max@example.com")
    private let calendly = Snippet(trigger: "my calendly", expansion: "https://calendly.com/max")

    // MARK: - Boost terms

    func testTheTriggersAreTheBoostTerms() {
        XCTAssertEqual(SnippetExpander.boostTerms([email, calendly]), ["my email", "my calendly"])
    }

    func testUnfinishedSnippetsAreNotBoosted() {
        let noText = Snippet(trigger: "sign off", expansion: " ")
        XCTAssertEqual(SnippetExpander.boostTerms([noText, email]), ["my email"])
    }

    func testBoostTermsAreTrimmedAndDeduplicatedIgnoringCase() {
        let shouted = Snippet(trigger: "  MY EMAIL! ", expansion: "other@example.com")
        XCTAssertEqual(SnippetExpander.boostTerms([email, shouted]), ["my email"])
        XCTAssertEqual(SnippetExpander.boostTerms([shouted, email]), ["MY EMAIL"])
    }

    func testATriggerWithNoLetterIsNotBoosted() {
        let arrow = Snippet(trigger: "->", expansion: "→")
        XCTAssertEqual(SnippetExpander.boostTerms([arrow]), [])
    }

    func testDictionaryTermsComeFirstAndAreNotRepeated() {
        XCTAssertEqual(RecognitionBoost.terms(dictionary: ["GitHub", "Calendly"],
                                              snippets: ["calendly", "my email"]),
                       ["GitHub", "Calendly", "my email"])
    }

    /// The field's terms join the same list, last, under the same dedupe (#89).
    ///
    /// `field:` defaults to empty, so without a row that passes it the order and the cross-list
    /// dedupe only ever run over two lists — and a caller that forgets the argument drops the
    /// field's terms with nothing to notice. Mutations: move `field` before the dictionary and
    /// the order changes; delete the `seen` set and "calendly" and "github" reappear.
    func testFieldTermsComeLastAndAreDeduplicatedAcrossAllThreeLists() {
        XCTAssertEqual(RecognitionBoost.terms(dictionary: ["GitHub", "Calendly"],
                                              snippets: ["calendly", "my email"],
                                              field: ["Cherith", "github", "Nyiragongo"]),
                       ["GitHub", "Calendly", "my email", "Cherith", "Nyiragongo"])
    }

    /// The dictionary's spelling wins over the field's, which is the order's whole point: someone
    /// writing "github" mid-sentence must not displace the "GitHub" their dictionary insists on.
    func testTheFieldDoesNotDisplaceADictionarySpelling() {
        XCTAssertEqual(RecognitionBoost.terms(dictionary: ["GitHub"], snippets: [],
                                              field: ["github", "Nyiragongo"]),
                       ["GitHub", "Nyiragongo"])
    }

    // MARK: - One clip's settings

    private func settings(dictionaryBoost: Bool, snippetTriggers: [String]) -> TranscriptionSettings {
        TranscriptionSettings(
            selectedLanguage: "en", translateToEnglish: false, suppressBlankAudio: true,
            showTimestamps: false, temperature: 0, noSpeechThreshold: 0.6, initialPrompt: "",
            useBeamSearch: false, beamSize: 5, useAsianAutocorrect: false,
            customDictionaryEnabled: true, customDictionaryBoostEnabled: dictionaryBoost,
            customDictionaryEntries: [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")],
            useSurroundingTextAsContext: false, snippetTriggers: snippetTriggers)
    }

    func testTheClipBoostsSnippetTriggersEvenWithTheDictionaryBoostOff() {
        XCTAssertEqual(settings(dictionaryBoost: false, snippetTriggers: ["my email"]).recognitionBoostTerms,
                       ["my email"])
    }

    func testTheClipBoostsBothWhenBothAreOn() {
        XCTAssertEqual(settings(dictionaryBoost: true, snippetTriggers: ["my email"]).recognitionBoostTerms,
                       ["GitHub", "my email"])
    }

    func testAClipWithoutSnippetTriggersBoostsWhatItDidBefore() {
        XCTAssertEqual(settings(dictionaryBoost: true, snippetTriggers: []).recognitionBoostTerms, ["GitHub"])
        XCTAssertEqual(settings(dictionaryBoost: false, snippetTriggers: []).recognitionBoostTerms, [])
    }

    // MARK: - Preferences

    /// The dictionary half the engines reading preferences add to a clip's snippet triggers.
    func testPreferencesBoostTheDictionaryOnlyWithBothSwitchesOn() {
        let prefs = CoreTestEnvironment.preferences
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        prefs.customDictionaryEnabled = true
        XCTAssertEqual(prefs.dictionaryBoostTerms, [])
        prefs.customDictionaryBoostEnabled = true
        XCTAssertEqual(prefs.dictionaryBoostTerms, ["GitHub"])
        prefs.customDictionaryEnabled = false
        XCTAssertEqual(prefs.dictionaryBoostTerms, [])
    }

    // MARK: - Stored format

    func testASnippetRoundTrips() throws {
        let data = try JSONEncoder().encode([email])
        XCTAssertEqual(try JSONDecoder().decode([Snippet].self, from: data), [email])
    }

    /// One snippet missing a field must not cost the user every other one: the array is decoded
    /// as a whole.
    func testAMissingFieldLoadsAsBlank() throws {
        let json = #"[{"id":"5B1D7C0E-6A2B-4F3C-9D8E-1A2B3C4D5E6F","trigger":"my email"},{"trigger":"sign off","expansion":"Max"}]"#
        let snippets = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        XCTAssertEqual(snippets.map(\.trigger), ["my email", "sign off"])
        XCTAssertEqual(snippets.map(\.expansion), ["", "Max"])
        XCTAssertEqual(snippets[0].id.uuidString, "5B1D7C0E-6A2B-4F3C-9D8E-1A2B3C4D5E6F")
    }

    /// A snippet stored without an id keeps the same one from read to read, or the page would
    /// take it for a new snippet every time.
    func testAMissingIdIsTheSameOnEveryRead() throws {
        let json = Data(#"[{"trigger":"sign off","expansion":"Max"},{"trigger":"my email","expansion":"m@x"}]"#.utf8)
        let first = try JSONDecoder().decode([Snippet].self, from: json)
        let second = try JSONDecoder().decode([Snippet].self, from: json)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertNotEqual(first[0].id, first[1].id)
    }

    // MARK: - What makes a trigger

    func testATriggerNeedsALetterOrADigit() {
        XCTAssertFalse(Snippet(trigger: "@", expansion: "at").isComplete)
        XCTAssertFalse(Snippet(trigger: " -> ", expansion: "→").isComplete)
        XCTAssertTrue(Snippet(trigger: "c++", expansion: "C++").isComplete)
        XCTAssertTrue(Snippet(trigger: "42", expansion: "the answer").isComplete)
    }

    /// Two triggers with the same key fire on the same words, so the editor refuses the second.
    func testTriggersThatMatchTheSameWordsShareAKey() {
        let key = Snippet(trigger: "sign off").triggerKey
        XCTAssertEqual(Snippet(trigger: "  Sign off! ").triggerKey, key)
        XCTAssertEqual(Snippet(trigger: "SIGN-OFF").triggerKey, key)
        XCTAssertEqual(Snippet(trigger: "sign   off.").triggerKey, key)
        XCTAssertNotEqual(Snippet(trigger: "sign of").triggerKey, key)
        XCTAssertEqual(Snippet(trigger: "l’adresse").triggerKey, Snippet(trigger: "L'adresse").triggerKey)
    }

    /// A later version may add fields; this one reads what it knows.
    func testUnknownFieldsAreIgnored() throws {
        let json = #"[{"id":"5B1D7C0E-6A2B-4F3C-9D8E-1A2B3C4D5E6F","trigger":"t","expansion":"e","richText":true}]"#
        let snippets = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        XCTAssertEqual(snippets.map(\.expansion), ["e"])
    }
}

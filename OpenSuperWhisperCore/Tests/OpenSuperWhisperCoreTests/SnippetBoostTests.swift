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

    // MARK: - One clip's settings

    private func settings(dictionary: [CustomDictionaryEntry], snippetTriggers: [String]) -> TranscriptionSettings {
        TranscriptionSettings(
            selectedLanguage: "en", translateToEnglish: false, suppressBlankAudio: true,
            showTimestamps: false, temperature: 0, noSpeechThreshold: 0.6, initialPrompt: "",
            useBeamSearch: false, beamSize: 5, useAsianAutocorrect: false,
            customDictionaryEnabled: true, customDictionaryEntries: dictionary,
            useSurroundingTextAsContext: false, snippetTriggers: snippetTriggers)
    }

    private let gitHub = CustomDictionaryEntry(original: "git hub", replacement: "GitHub")
    private let gitHubSpellingOnly = CustomDictionaryEntry(original: "git hub", replacement: "GitHub",
                                                           boostsRecognition: false)

    func testTheClipBoostsSnippetTriggersEvenWhenNoEntrySteersRecognition() {
        XCTAssertEqual(settings(dictionary: [gitHubSpellingOnly], snippetTriggers: ["my email"]).recognitionBoostTerms,
                       ["my email"])
    }

    func testTheClipBoostsBothTheDictionaryAndTheTriggers() {
        XCTAssertEqual(settings(dictionary: [gitHub], snippetTriggers: ["my email"]).recognitionBoostTerms,
                       ["GitHub", "my email"])
    }

    func testAClipWithoutSnippetTriggersBoostsTheDictionaryAlone() {
        XCTAssertEqual(settings(dictionary: [gitHub], snippetTriggers: []).recognitionBoostTerms, ["GitHub"])
        XCTAssertEqual(settings(dictionary: [gitHubSpellingOnly], snippetTriggers: []).recognitionBoostTerms, [])
    }

    // MARK: - Preferences

    /// The dictionary half the engines reading preferences add to a clip's snippet triggers: it
    /// follows the dictionary's own switch and each entry's, and nothing else.
    func testPreferencesBoostTheEntriesThatSteerRecognitionWhileTheDictionaryIsOn() {
        let prefs = CoreTestEnvironment.preferences
        prefs.customDictionaryEntries = [gitHub,
                                         CustomDictionaryEntry(original: "Maxime", replacement: "Maxim",
                                                               boostsRecognition: false)]
        prefs.customDictionaryEnabled = true
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

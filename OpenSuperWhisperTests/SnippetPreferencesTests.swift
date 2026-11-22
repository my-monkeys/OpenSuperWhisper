import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The switches around snippets (#167): what the dictation pipeline expands, and what a clip
/// boosts. The matching itself is covered in the core's `SnippetExpanderTests`.
final class SnippetPreferencesTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private let email = Snippet(trigger: "my email", expansion: "max@example.com")

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    func testSnippetsExpandOnAFreshInstall() {
        prefs.snippets = [email]
        XCTAssertEqual(prefs.expandSnippets("My email."), "max@example.com")
    }

    func testSnippetsOffLeaveTheTextAlone() {
        prefs.snippets = [email]
        prefs.snippetsEnabled = false
        XCTAssertEqual(prefs.expandSnippets("My email."), "My email.")
    }

    /// The dictionary ran before the cleanup; a trigger it rewrote is only recognised while it
    /// is on, since only then was the text rewritten.
    func testTheDictionaryFormOfATriggerFollowsTheDictionarySwitch() {
        prefs.snippets = [Snippet(trigger: "my monkey site", expansion: "https://my-monkey.fr")]
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "my monkey", replacement: "MyMonkey")]

        prefs.customDictionaryEnabled = true
        XCTAssertEqual(prefs.expandSnippets("Open MyMonkey site now"), "Open https://my-monkey.fr now")

        prefs.customDictionaryEnabled = false
        XCTAssertEqual(prefs.expandSnippets("Open MyMonkey site now"), "Open MyMonkey site now")
    }

    func testADictationBoostsTriggersOnlyWithBothSwitchesOn() {
        prefs.snippets = [email]
        XCTAssertEqual(prefs.dictationSnippetTriggers, [], "the boost is opt-in")

        prefs.snippetsBoostEnabled = true
        XCTAssertEqual(prefs.dictationSnippetTriggers, ["my email"])

        prefs.snippetsEnabled = false
        XCTAssertEqual(prefs.dictationSnippetTriggers, [])
    }

    /// A dropped file or a CLI run expands no snippet, so nothing biases it toward one. Only the
    /// dictation paths set the triggers on their clip.
    func testAClipThatIsNotADictationBoostsNoTrigger() {
        prefs.snippets = [email]
        prefs.snippetsBoostEnabled = true
        XCTAssertEqual(Settings().snippetTriggers, [])
        XCTAssertEqual(Settings().recognitionBoostTerms, [])
    }

    /// The live preview boosts what the dictation's file pass does.
    func testTheLivePreviewBoostsTheSameTermsAsTheDictation() {
        prefs.snippets = [email]
        prefs.snippetsBoostEnabled = true
        prefs.customDictionaryEnabled = true
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        var clip = Settings()
        clip.snippetTriggers = prefs.dictationSnippetTriggers
        XCTAssertEqual(clip.recognitionBoostTerms, ["GitHub", "my email"])
        XCTAssertEqual(RecognitionBoost.terms(dictionary: prefs.dictionaryBoostTerms,
                                              snippets: prefs.dictationSnippetTriggers),
                       clip.recognitionBoostTerms)
    }

    // MARK: - Fitting to the field

    /// Mid-sentence, a dictation loses the capital and the period the engine gave it, but a
    /// snippet's text is the user's own spelling.
    @MainActor
    func testFittingToTheFieldKeepsASnippetsCapitalAndFinalMark() {
        prefs.snippets = [Snippet(trigger: "sign off", expansion: "Max Costa"),
                          Snippet(trigger: "bye now", expansion: "See you soon!")]
        let field = TextAroundCaret(before: "Thanks and", after: " see you")
        XCTAssertEqual(TranscriptInserter.prepared("Max Costa", fitToField: true, language: "en",
                                                   readField: { field }).fitted, " Max Costa")
        XCTAssertEqual(TranscriptInserter.prepared("See you soon!", fitToField: true, language: "en",
                                                   readField: { field }).fitted, " See you soon!")

        prefs.snippetsEnabled = false
        XCTAssertEqual(TranscriptInserter.prepared("See you soon!", fitToField: true, language: "en",
                                                   readField: { field }).fitted, " see you soon")
    }
}

import XCTest
import OpenSuperWhisperCore

@testable import OpenSuperWhisper

/// The "Your words" step: what a typed word becomes, and that only Continue writes it.
@MainActor
final class OnboardingWordsTests: XCTestCase {

    private var savedEntries: [CustomDictionaryEntry] = []
    private var savedEnabled = false

    override func setUp() {
        super.setUp()
        let prefs = AppPreferences.shared
        savedEntries = prefs.customDictionaryEntries
        savedEnabled = prefs.customDictionaryEnabled
        prefs.customDictionaryEntries = []
        prefs.customDictionaryEnabled = false
    }

    override func tearDown() {
        AppPreferences.shared.customDictionaryEntries = savedEntries
        AppPreferences.shared.customDictionaryEnabled = savedEnabled
        super.tearDown()
    }

    private func makeViewModel(fullName: String = "") -> OnboardingViewModel {
        OnboardingViewModel(system: .staged(fullUserName: fullName))
    }

    // MARK: Normalisation

    func testWordsAreTrimmedAndBlanksIgnored() {
        var words = OnboardingWords.adding("  Figma \n", to: [], existing: [])
        words = OnboardingWords.adding("   ", to: words, existing: [])
        XCTAssertEqual(words, ["Figma"])
    }

    func testDuplicatesAreIgnoredIgnoringCase() {
        let words = OnboardingWords.adding("figma", to: ["Figma"], existing: [])
        XCTAssertEqual(words, ["Figma"])
    }

    func testWordsAlreadyInTheDictionaryAreIgnored() {
        let existing = [CustomDictionaryEntry(original: "Kubernetes", replacement: "Kubernetes"),
                        CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        XCTAssertEqual(OnboardingWords.adding("kubernetes", to: [], existing: existing), [])
        XCTAssertEqual(OnboardingWords.adding("github", to: [], existing: existing), [])
        XCTAssertEqual(OnboardingWords.adding("Git Hub", to: [], existing: existing), [])
    }

    func testTheListStopsAtTheLimit() {
        let full = (1...OnboardingWords.limit).map { "word\($0)" }
        XCTAssertEqual(OnboardingWords.adding("one more", to: full, existing: []), full)
    }

    // MARK: Continue and Skip

    func testContinueWritesPlainWordEntriesAndTurnsTheDictionaryOn() {
        let viewModel = makeViewModel()
        viewModel.addWord("Figma")
        viewModel.wordDraft = "Marie-Claire"
        viewModel.commitWords()

        let entries = AppPreferences.shared.customDictionaryEntries
        XCTAssertEqual(entries.map(\.original), ["Figma", "Marie-Claire"])
        XCTAssertEqual(entries.map(\.replacement), ["Figma", "Marie-Claire"])
        XCTAssertTrue(entries.allSatisfy { $0.kind == .word && $0.alternates.isEmpty
            && !$0.isRegex && $0.spacing == .standalone })
        XCTAssertTrue(AppPreferences.shared.customDictionaryEnabled)
    }

    func testContinueKeepsExistingEntriesAndSkipsWordsTheyGained() {
        let viewModel = makeViewModel()
        viewModel.addWord("Figma")
        let existing = CustomDictionaryEntry(original: "figma", replacement: "Figma")
        AppPreferences.shared.customDictionaryEntries = [existing]
        viewModel.commitWords()

        XCTAssertEqual(AppPreferences.shared.customDictionaryEntries, [existing])
    }

    func testSkipWritesNothing() {
        let viewModel = makeViewModel()
        viewModel.wordDraft = "Figma"
        // Skip only moves to the next step: `commitWords` is never called.
        XCTAssertEqual(AppPreferences.shared.customDictionaryEntries, [])
        XCTAssertFalse(AppPreferences.shared.customDictionaryEnabled)
    }

    func testContinueWithNoWordsLeavesTheDictionarySwitchAlone() {
        makeViewModel().commitWords()
        XCTAssertFalse(AppPreferences.shared.customDictionaryEnabled)
    }

    // MARK: Suggestion

    func testFullNameIsSuggestedNotAdded() {
        let viewModel = makeViewModel(fullName: "Maxim Costa")
        XCTAssertEqual(viewModel.suggestedWord, "Maxim Costa")
        XCTAssertEqual(viewModel.words, [])

        viewModel.addWord("Maxim Costa")
        XCTAssertNil(viewModel.suggestedWord)
    }

    func testNoSuggestionWithoutAName() {
        XCTAssertNil(makeViewModel(fullName: "  ").suggestedWord)
    }

    // MARK: Step order

    func testWordsComeRightAfterTheModel() {
        XCTAssertEqual(OnboardingStep.allCases, [.shortcut, .model, .words, .permissions, .firstTry])
        XCTAssertEqual(OnboardingStep.model.next, .words)
        XCTAssertEqual(OnboardingStep.words.next, .permissions)
        XCTAssertEqual(OnboardingStep.words.previous, .model)
    }
}

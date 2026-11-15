import XCTest
@testable import OpenSuperWhisper

/// The filler list follows the dictation's language: "um" is a hesitation in English and a
/// word in German ("um 10 Uhr"), so one English list for everything ate real words (#338).
final class FillerWordsLanguageTests: XCTestCase {

    private var scratch: ScratchPreferences!

    override func setUp() {
        scratch = ScratchPreferences()
        AppPreferences.shared.removeFillerWords = true
    }

    override func tearDown() {
        scratch.restore()
    }

    private func cleaned(_ text: String, _ language: String?) -> String {
        AppPreferences.shared.cleanTranscription(text, language: language)
    }

    func testGermanKeepsUm() {
        let text = "Ich habe morgen um 10 Uhr einen Termin beim Finanzamt."
        XCTAssertEqual(cleaned(text, "de"), text)
        XCTAssertEqual(cleaned("Er kommt, um zu helfen.", "de"), "Er kommt, um zu helfen.")
    }

    func testGermanRemovesItsHesitations() {
        XCTAssertEqual(cleaned("Ich äh glaube, ähm, das stimmt.", "de"), "Ich glaube, das stimmt.")
        XCTAssertEqual(cleaned("Ähm ja", "de"), "ja")
    }

    func testBoundaryHandlesNonASCIILetters() {
        XCTAssertEqual(cleaned("Das ist ähmlich wie vorher.", "de"), "Das ist ähmlich wie vorher.")
        XCTAssertEqual(cleaned("Eine Mähne", "de"), "Eine Mähne")
    }

    func testFrenchRemovesEuhAndKeepsUm() {
        XCTAssertEqual(cleaned("Je euh pense que um reste.", "fr"), "Je pense que um reste.")
    }

    func testEnglishListIsUnchanged() {
        XCTAssertEqual(cleaned("So um I uh think, er, yes", "en"), "So I think, yes")
        XCTAssertEqual(cleaned("So um I think", "en-US"), "So I think")
    }

    func testUnknownLanguageRemovesOnlyHums() {
        XCTAssertEqual(cleaned("um hmm uh mm ok", "xx"), "um uh ok")
        XCTAssertEqual(cleaned("um hmm uh ok", nil).contains("hmm"), false)
    }

    func testCustomPatternAppliesToEveryLanguage() {
        AppPreferences.shared.fillerWordsPattern = "\\b(um)\\b\\s*"
        XCTAssertEqual(cleaned("um zehn Uhr", "de"), "zehn Uhr")
        XCTAssertEqual(cleaned("so um ok", "fr"), "so ok")
    }

    func testPatternChoiceIsPure() {
        let stock = AppPreferences.defaultFillerPattern
        XCTAssertEqual(AppPreferences.fillerPattern(forLanguage: "en", customPattern: stock), stock)
        XCTAssertEqual(AppPreferences.fillerPattern(forLanguage: "de", customPattern: "x"), "x")
        XCTAssertFalse(AppPreferences.fillerPattern(forLanguage: "de", customPattern: stock).contains("um"))
        XCTAssertFalse(AppPreferences.fillerPattern(forLanguage: nil, customPattern: stock).contains("um"))
    }

    func testAutoDetectsLanguageFromText() {
        let german = "Ich habe morgen um 10 Uhr einen Termin beim Finanzamt."
        XCTAssertEqual(AppPreferences.fillerLanguage(declared: "auto", text: german), "de")
        XCTAssertEqual(cleaned(german, "auto"), german)
        XCTAssertEqual(AppPreferences.fillerLanguage(declared: nil, text: german), "de")
    }

    func testDeclaredLanguageWinsOverDetection() {
        XCTAssertEqual(AppPreferences.fillerLanguage(declared: "fr", text: "Ich habe einen Termin."), "fr")
    }

    func testUndetectableTextFallsBackToUnknown() {
        XCTAssertNil(AppPreferences.fillerLanguage(declared: "auto", text: ""))
        XCTAssertNil(AppPreferences.fillerLanguage(declared: KeyboardLanguage.selectionCode, text: "12 34"))
    }
}

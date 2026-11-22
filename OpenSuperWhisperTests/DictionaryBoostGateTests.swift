import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The custom dictionary keeps two behaviors apart:
/// - **Replacement** (`shouldApplyCustomDictionary`): exact text fix, on whenever the dictionary
///   is enabled and non-empty.
/// - **Recognition boosting** (`recognitionBoostTerms`): decided entry by entry, because fuzzy
///   boosting over-corrects short, common terms. There is no global switch for it (#234).
final class DictionaryBoostGateTests: XCTestCase {

    private var saved: (enabled: Bool, data: Data?)!

    private let word = CustomDictionaryEntry(original: "Rsets", replacement: "Rsets")
    private let correction = CustomDictionaryEntry(original: "Maxime", replacement: "Maxim",
                                                   boostsRecognition: false)

    override func setUp() {
        let p = AppPreferences.shared
        saved = (p.customDictionaryEnabled, DefaultsStore.current.data(forKey: "customDictionaryData"))
        p.customDictionaryEntries = [word, correction]
    }

    override func tearDown() {
        let p = AppPreferences.shared
        p.customDictionaryEnabled = saved.enabled
        if let d = saved.data { DefaultsStore.current.set(d, forKey: "customDictionaryData") }
        else { DefaultsStore.current.removeObject(forKey: "customDictionaryData") }
    }

    private func settings(enabled: Bool) -> Settings {
        AppPreferences.shared.customDictionaryEnabled = enabled
        return Settings()
    }

    func testReplacementOnWhenTheDictionaryIsOn() {
        XCTAssertTrue(settings(enabled: true).shouldApplyCustomDictionary)
        XCTAssertFalse(settings(enabled: false).shouldApplyCustomDictionary)
    }

    func testOnlyEntriesThatSteerRecognitionAreBoosted() {
        XCTAssertEqual(settings(enabled: true).recognitionBoostTerms, ["Rsets"],
                       "the correction rewrites, but its switch is off")
        XCTAssertEqual(AppPreferences.shared.dictionaryBoostTerms, ["Rsets"])
    }

    func testNothingIsBoostedWhenTheDictionaryIsOff() {
        XCTAssertEqual(settings(enabled: false).recognitionBoostTerms, [])
        XCTAssertEqual(AppPreferences.shared.dictionaryBoostTerms, [])
    }
}

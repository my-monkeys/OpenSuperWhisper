import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Which style a dictation gets (#160): the app's own, else the default, else Raw.
final class WritingStylePreferencesTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private let charity = WritingStyle(id: "charity", name: "Charity", instructions: "Warm and plain.")

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    func testAFreshInstallWritesRaw() {
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.mail"), .raw)
    }

    func testTheDefaultStyleAppliesEverywhere() {
        prefs.writingStyleID = WritingStyle.proID
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.mail"), .pro)
        XCTAssertEqual(prefs.writingStyle(for: nil), .pro)
    }

    /// Bundle identifiers are matched case-insensitively, like the other per-app rules.
    func testAnAppStyleWinsOverTheDefault() {
        prefs.writingStyleID = WritingStyle.proID
        prefs.customWritingStyles = [charity]
        prefs.appWritingStyles = ["net.whatsapp.whatsapp": "charity"]
        XCTAssertEqual(prefs.writingStyle(for: "net.whatsapp.WhatsApp"), charity)
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.mail"), .pro)
    }

    /// What a history row keeps: the style's name only when cleanup ran and the style added
    /// something to it. Whether it ran is the dictation's own answer, so an app set to clean up
    /// gets its style named while the global switch is off.
    @MainActor
    func testTheHistoryNamesAStyleOnlyWhenItShapedTheText() {
        prefs.aiPostProcessingEnabled = false
        XCTAssertNil(HistoryRestyle.label(for: .pro, cleanedUp: false))
        XCTAssertEqual(HistoryRestyle.label(for: .pro, cleanedUp: true), "Pro")
        XCTAssertNil(HistoryRestyle.label(for: .raw, cleanedUp: true))
    }

    /// The rewrite button follows cleanup being on anywhere: with the global switch off, one app
    /// set to clean up is enough, and a row from any app can then be rewritten.
    @MainActor
    func testAHistoryRowCanBeRewrittenWhenOneAppCleansUp() {
        let row = Recording(id: UUID(), timestamp: Date(), fileName: "a.wav", transcription: "Salut",
                            duration: 1, status: .completed, progress: 1, rawTranscription: "salut")
        prefs.aiPostProcessingEnabled = false
        XCTAssertFalse(HistoryRestyle.isAvailable(for: row))
        prefs.appCleanupOverrides = ["com.automattic.beeper.desktop": true]
        XCTAssertTrue(HistoryRestyle.isAvailable(for: row))
    }

    /// An override that turns cleanup off, or one on an app switched off on the Per app page,
    /// leaves cleanup off everywhere. A site key counts through its app.
    func testCleanupIsOnSomewhereOnlyThroughALiveOverride() {
        prefs.aiPostProcessingEnabled = false
        prefs.appCleanupOverrides = ["com.apple.notes": false]
        XCTAssertFalse(prefs.cleanupOnSomewhere)

        prefs.appCleanupOverrides = ["company.thebrowser.dia|mail.google.com": true]
        XCTAssertTrue(prefs.cleanupOnSomewhere)
        prefs.perAppDisabledBundleIDs = ["company.thebrowser.dia"]
        XCTAssertFalse(prefs.cleanupOnSomewhere)

        prefs.aiPostProcessingEnabled = true
        XCTAssertTrue(prefs.cleanupOnSomewhere)
    }

    func testADeletedStyleFallsBackToRaw() {
        prefs.appWritingStyles = ["com.apple.mail": "gone"]
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.mail"), .raw)
    }
}

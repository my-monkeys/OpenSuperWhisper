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

    func testADeletedStyleFallsBackToRaw() {
        prefs.appWritingStyles = ["com.apple.mail": "gone"]
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.mail"), .raw)
    }
}

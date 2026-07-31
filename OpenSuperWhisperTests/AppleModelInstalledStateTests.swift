import XCTest

@testable import OpenSuperWhisper

/// The Apple Speech model rows ask "are this language's assets on this Mac", and the answer
/// is matched against the locale list Speech returns. Identifier formatting differs between
/// call sites ("fr_FR" vs "fr-FR"), so the comparison has to go through language + region
/// rather than string equality, or an installed model renders a Download button (#46).
final class AppleModelInstalledStateTests: XCTestCase {

    func testMatchesAcrossIdentifierSeparators() {
        let installed = [Locale(identifier: "fr-FR"), Locale(identifier: "en_US")]
        XCTAssertTrue(LanguageUtil.isInstalled(Locale(identifier: "fr_FR"), in: installed))
        XCTAssertTrue(LanguageUtil.isInstalled(Locale(identifier: "en-US"), in: installed))
    }

    func testDistinguishesRegionalVariants() {
        let installed = [Locale(identifier: "fr_FR")]
        XCTAssertFalse(LanguageUtil.isInstalled(Locale(identifier: "fr_CH"), in: installed),
                       "fr_CH is a separate download from fr_FR")
    }

    /// The language rows resolve to a full locale, but a bare code has to keep working: it
    /// asks whether the language is available at all, so any region counts.
    func testRegionlessLocaleMatchesAnyRegion() {
        let installed = [Locale(identifier: "pt_BR")]
        XCTAssertTrue(LanguageUtil.isInstalled(Locale(identifier: "pt"), in: installed))
        XCTAssertFalse(LanguageUtil.isInstalled(Locale(identifier: "de"), in: installed))
    }

    func testEmptyInventoryInstallsNothing() {
        XCTAssertFalse(LanguageUtil.isInstalled(Locale(identifier: "en_US"), in: []))
    }
}

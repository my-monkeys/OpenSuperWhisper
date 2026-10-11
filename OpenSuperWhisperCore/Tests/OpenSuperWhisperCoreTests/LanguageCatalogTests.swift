import XCTest

@testable import OpenSuperWhisperCore

/// The Whisper language list is read from the library rather than hand-maintained, because the
/// hand-written one kept omitting languages Whisper supported. Ukrainian, Vietnamese and Czech
/// each reached us as a user report before anyone could select them. These pin that the list
/// really does come from the transcriber.
final class LanguageCatalogTests: CoreTestCase {

    func testCoversWhatWhisperActuallySupports() {
        // Whisper ships ~99 languages; the old hand-written list held 22.
        XCTAssertGreaterThan(LanguageUtil.availableLanguages.count, 90,
                             "the list looks hand-written again, not read from the library")
    }

    /// The three that had to be reported by users. If the list ever stops being derived, these
    /// are the first to fall off again.
    func testIncludesTheLanguagesUsersHadToAskFor() {
        for code in ["uk", "vi", "cs"] {
            XCTAssertTrue(LanguageUtil.availableLanguages.contains(code),
                          "\(code) is missing, though Whisper transcribes it")
        }
    }

    func testAutoDetectIsFirst() {
        XCTAssertEqual(LanguageUtil.availableLanguages.first, "auto")
    }

    func testEveryCodeHasADisplayName() {
        for code in LanguageUtil.availableLanguages {
            let name = LanguageUtil.languageNames[code]
            XCTAssertNotNil(name, "\(code) would render as a bare code in the picker")
            XCTAssertNotEqual(name, code, "\(code) has no readable name")
        }
    }

    /// Names we already shipped must not change spelling under users.
    func testKeepsTheNamesWeAlreadyShipped() {
        XCTAssertEqual(LanguageUtil.languageNames["auto"], "Auto-detect")
        XCTAssertEqual(LanguageUtil.languageNames["vi"], "Vietnamese")
        XCTAssertEqual(LanguageUtil.languageNames["he"], "Hebrew")
        XCTAssertEqual(LanguageUtil.languageNames["en"], "English")
    }

    /// Whisper spells its own names in lowercase, which would look like a bug in the picker.
    func testDerivedNamesAreCapitalised() {
        XCTAssertEqual(LanguageUtil.languageNames["cs"], "Czech")
        for code in LanguageUtil.availableLanguages {
            let name = LanguageUtil.languageNames[code] ?? ""
            XCTAssertEqual(name.first, name.first?.uppercased().first,
                           "\(code) renders as \"\(name)\"")
        }
    }

    func testNoDuplicates() {
        XCTAssertEqual(Set(LanguageUtil.availableLanguages).count,
                       LanguageUtil.availableLanguages.count)
    }

    /// The picker is long now, so it has to be ordered by what the user reads, not by Whisper's
    /// internal ids.
    func testSortedByDisplayNameAfterAutoDetect() {
        let names = LanguageUtil.availableLanguages.dropFirst().map { LanguageUtil.displayName(for: $0) }
        XCTAssertEqual(names, names.sorted())
    }
}

import XCTest

@testable import OpenSuperWhisper

/// The text size setting has to reach every window, not just the one it lives in.
///
/// It shipped covering Settings only. The main window — the history list people actually read —
/// never received the environment value, and most of its text used semantic styles like
/// `.caption` that follow the system size but ignore the app's own slider entirely. So the
/// setting worked where you set it and nowhere you would use it. Reported twice by the user who
/// asked for the feature in the first place.
///
/// Grep-based, deliberately: the failure is a call site nobody converted, which no amount of
/// exercising the view model would catch.
final class TextScaleCoverageTests: XCTestCase {

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenSuperWhisperTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("OpenSuperWhisper")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Semantic font styles scale with macOS's text size but not with ours, so a window full of
    /// them ignores the slider however the environment is set.
    private static let semanticFontStyles = [
        ".font(.caption)", ".font(.caption2)", ".font(.footnote)", ".font(.subheadline)",
        ".font(.body)", ".font(.headline)", ".font(.title)", ".font(.title2)", ".font(.title3)",
        ".font(.largeTitle)",
    ]

    /// Every window's own text, in the files that draw it.
    private static let userFacingViews = [
        "ContentView.swift",
        "Settings.swift",
        "Indicator/IndicatorWindow.swift",
        "Indicator/IndicatorElementView.swift",
        "Settings/DictionaryBadgeEditor.swift",
        "Settings/DownloadsSidebarCard.swift",
        "Settings/PunctuationCalibrationView.swift",
        "Onboarding/OnboardingView.swift",
        "Onboarding/OnboardingStepper.swift",
        "Onboarding/OnboardingShortcutStep.swift",
        "Onboarding/OnboardingKeyboardView.swift",
        "Onboarding/OnboardingModelStep.swift",
        "Onboarding/OnboardingPermissionsStep.swift",
        "Onboarding/OnboardingFirstTryStep.swift",
    ]

    func testNoWindowUsesAFontThatIgnoresTheSetting() throws {
        for path in Self.userFacingViews {
            let text = try source(path)
            for style in Self.semanticFontStyles {
                XCTAssertFalse(text.contains(style),
                               "\(path) uses \(style), which the text size setting cannot reach")
            }
        }
    }

    /// A fixed point size ignores the setting just as thoroughly.
    func testNoWindowHardcodesAPointSize() throws {
        for path in Self.userFacingViews {
            let text = try source(path)
            XCTAssertFalse(text.contains(".font(.system(size:"),
                           "\(path) sets a fixed point size; use scaledFont")
        }
    }

    /// Each window has to inject the value, or its `scaledFont` calls silently fall back to 1.0.
    func testEveryWindowInjectsTheScale() throws {
        let app = try source("OpenSuperWhisperApp.swift")
        XCTAssertTrue(app.contains("\\.appTextScale"),
                      "the main window and onboarding would ignore the setting")

        let settings = try source("Settings.swift")
        XCTAssertTrue(settings.contains("\\.appTextScale"))

        let indicator = try source("Indicator/IndicatorWindowManager.swift")
        XCTAssertTrue(indicator.contains("\\.appTextScale"),
                      "the recording bubble would ignore the setting")
    }

    /// Read through a mechanism that publishes changes. Reading the preference directly is what
    /// made the slider look dead in 0.10.1: the value was written and nothing re-read it.
    func testTheMainWindowReadsTheScaleObservably() throws {
        let app = try source("OpenSuperWhisperApp.swift")

        XCTAssertTrue(app.contains("@AppStorage(\"textScale\", store: DefaultsStore.current)"),
                      "an unobserved read means the slider only applies after a relaunch")
        XCTAssertFalse(app.contains("\\.appTextScale, AppPreferences.shared.textScale"),
                       "that read is not observed")
    }

    /// The key the window reads has to be the key the preference writes.
    func testTheKeyMatchesThePreference() throws {
        let prefs = try source("Utils/AppPreferences.swift")
        XCTAssertTrue(prefs.contains("key: \"textScale\""))
    }
}

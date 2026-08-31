import XCTest

@testable import OpenSuperWhisper

/// What every engine owes a transcription before handing it back.
///
/// These exist because the steps were copied into four engines and missing from the fifth, so
/// dictionary rules silently did nothing for anyone using a remote server (#101). The last test
/// is the one that matters most: it checks the omission cannot happen again.
final class TranscriptionPostProcessingTests: XCTestCase {

    private func settingsWithDictionary(_ entries: [CustomDictionaryEntry]) -> Settings {
        var settings = Settings()
        settings.customDictionaryEnabled = true
        settings.customDictionaryEntries = entries
        return settings
    }

    func testTheDictionaryIsApplied() {
        let settings = settingsWithDictionary([
            CustomDictionaryEntry(original: "git hub", replacement: "GitHub")
        ])

        XCTAssertEqual(TranscriptionPostProcessing.finish("push it to git hub", settings: settings),
                       "push it to GitHub")
    }

    func testARegexRuleIsAppliedToo() {
        let settings = settingsWithDictionary([
            CustomDictionaryEntry(original: "deep[\\s-]+\\w+[\\s-]+\\w+",
                                  replacement: "deepseek harness", isRegex: true)
        ])

        XCTAssertEqual(TranscriptionPostProcessing.finish("run the deep seek harness now",
                                                          settings: settings),
                       "run the deepseek harness now")
    }

    func testTheTextIsTrimmed() {
        XCTAssertEqual(TranscriptionPostProcessing.finish("  hello  ", settings: Settings()),
                       "hello")
    }

    func testNothingHeardIsReportedAsSilence() {
        XCTAssertEqual(TranscriptionPostProcessing.finish("   \n ", settings: Settings()),
                       TranscriptionResult.noSpeech)
    }

    func testADisabledDictionaryChangesNothing() {
        var settings = Settings()
        settings.customDictionaryEnabled = false
        settings.customDictionaryEntries = [
            CustomDictionaryEntry(original: "git hub", replacement: "GitHub")
        ]

        XCTAssertEqual(TranscriptionPostProcessing.finish("git hub", settings: settings), "git hub")
    }

    // MARK: - The omission that started this

    /// Every engine has to run the shared step, and having one implementation does not by itself
    /// make that happen. The bug was not a wrong line, it was a missing one in the fifth copy of
    /// something duplicated four times, and nothing in the type system notices that.
    ///
    /// Reads the sources rather than the built product, so a new engine that forgets fails here
    /// with its own filename rather than in somebody's dictation weeks later.
    func testEveryEngineRunsTheSharedStep() throws {
        let engines = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OpenSuperWhisperTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("OpenSuperWhisper/Engines")

        let files = try FileManager.default.contentsOfDirectory(atPath: engines.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty, "no engine sources found at \(engines.path)")

        var checked = 0
        for name in files {
            let source = try String(contentsOf: engines.appendingPathComponent(name),
                                    encoding: .utf8)
            // Conformances only: the protocol itself and helpers are not engines.
            guard source.contains(": TranscriptionEngine"),
                  !name.hasPrefix("TranscriptionEngine") else { continue }
            checked += 1
            XCTAssertTrue(source.contains("TranscriptionPostProcessing.finish"),
                          "\(name) returns a transcription without the shared post-processing, "
                          + "so the dictionary and autocorrect do nothing there")
        }
        XCTAssertGreaterThanOrEqual(checked, 5, "expected every engine to be checked")
    }
}

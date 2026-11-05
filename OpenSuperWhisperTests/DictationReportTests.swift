import XCTest

@testable import OpenSuperWhisper
import OpenSuperWhisperCore

final class DictationReportTests: XCTestCase {

    private func draft(output: String = "Hello there.",
                       raw: String? = nil,
                       note: String = "",
                       language: String? = "fr",
                       translate: Bool = false,
                       timing: DictationTiming? = nil) -> DictationReportDraft {
        DictationReportDraft(note: note, modelUsed: "Parakeet Ultra", languageSetting: language,
                             translateToEnglish: translate, durationSeconds: 4, output: output,
                             rawOutput: raw, appVersion: "0.14.0 (63)", osVersion: "26.2",
                             timing: timing)
    }

    // MARK: - Message

    func testTheMessageCarriesTheSettingsAndTheOutput() {
        let message = DictationReport.message(for: draft(note: "spoke French, got English"),
                                              outputLimit: 2000, includeRaw: true)

        XCTAssertTrue(message.hasPrefix("Dictation reported as wrong.\nspoke French, got English\n"))
        XCTAssertTrue(message.contains("model: Parakeet Ultra"))
        XCTAssertTrue(message.contains("language: fr"))
        XCTAssertTrue(message.contains("duration: 4s"))
        XCTAssertTrue(message.contains("output: Hello there."))
    }

    func testAnEmptyNoteLeavesNoNoteLine() {
        let message = DictationReport.message(for: draft(note: "   "), outputLimit: 2000, includeRaw: true)

        XCTAssertEqual(message.split(separator: "\n").first, "Dictation reported as wrong.")
        XCTAssertTrue(message.contains("model:"))
    }

    func testTranslateToEnglishIsNamedOnlyWhenOn() {
        let on = DictationReport.message(for: draft(translate: true), outputLimit: 2000, includeRaw: true)
        let off = DictationReport.message(for: draft(translate: false), outputLimit: 2000, includeRaw: true)

        XCTAssertTrue(on.contains("translate to English: on"))
        XCTAssertFalse(off.contains("translate to English"))
    }

    func testTheRawTextIsSentOnlyWhenItDiffers() {
        let differs = DictationReport.message(for: draft(output: "cleaned", raw: "raw text"),
                                              outputLimit: 2000, includeRaw: true)
        let same = DictationReport.message(for: draft(output: "same", raw: "same"),
                                           outputLimit: 2000, includeRaw: true)

        XCTAssertTrue(differs.contains("raw: raw text"))
        XCTAssertFalse(same.contains("raw:"))
    }

    func testTheMessageCarriesTheTimingLineWhenMeasured() {
        var timing = DictationTiming()
        timing.totalMs = 4_300
        timing.transcribeMs = 1_200
        timing.cleanupMs = 600
        timing.transcribeAttempts = 1

        let message = DictationReport.message(for: draft(timing: timing), outputLimit: 2000, includeRaw: true)

        XCTAssertTrue(message.contains("timing: total 4.3 s · transcribe 1.2 s · cleanup 0.6 s · attempts 1"))
    }

    func testTheMessageHasNoTimingLineWithoutTiming() {
        let message = DictationReport.message(for: draft(), outputLimit: 2000, includeRaw: true)

        XCTAssertFalse(message.contains("timing:"))
    }

    /// The timing line is diagnostics, not payload: it may cost its own length and never a
    /// character of the dictated text. A note long enough that the timing line pushes the report
    /// past the endpoint's 4000-unit limit drops the line and sends the full output.
    func testDroppingTheTimingLineNeverShrinksTheDictatedText() {
        var timing = DictationTiming()
        timing.totalMs = 4_300
        let withTiming = draft(note: String(repeating: "a", count: 3_900), timing: timing)
        var withoutTiming = withTiming
        withoutTiming.timing = nil

        let submission = DictationReport.submission(for: withTiming)
        let reference = DictationReport.submission(for: withoutTiming)

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertFalse(submission.message.contains("timing:"))
        XCTAssertEqual(outputLine(in: submission.message), outputLine(in: reference.message))
        XCTAssertTrue(submission.message.contains("output: Hello there."))
    }

    private func outputLine(in message: String) -> String? {
        message.split(separator: "\n").first { $0.hasPrefix("output: ") }.map(String.init)
    }

    // MARK: - Submission

    func testAnOrdinaryReportSendsAsABugWithNoEmail() {
        let submission = DictationReport.submission(for: draft(output: "bonjour", raw: "Bonjour."))

        XCTAssertEqual(submission.kind, .bug)
        XCTAssertEqual(submission.email, "")
        XCTAssertEqual(submission.details, "OpenSuperWhisper 0.14.0 (63) · macOS 26.2")
        XCTAssertTrue(submission.message.contains("output: bonjour"))
        XCTAssertTrue(submission.message.contains("raw: Bonjour."))
        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
    }

    /// Output and raw text that together pass the byte limit drop the raw text first, so the
    /// output, the part the person is reporting, always sends.
    func testOversizedTextDropsTheRawFirstAndStillFits() {
        let submission = DictationReport.submission(for: draft(output: String(repeating: "あ", count: 2000),
                                                               raw: String(repeating: "い", count: 2000)))

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertTrue(submission.message.contains("output: ああ"))
        XCTAssertFalse(submission.message.contains("raw:"))
    }

    /// Even an output that alone would pass the limit (emoji count double toward it) sends rather
    /// than nothing, shortened until it fits.
    func testAnEnormousOutputIsShortenedToFit() {
        let submission = DictationReport.submission(for: draft(output: String(repeating: "😀", count: 5000)))

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertTrue(submission.message.contains("output: 😀"))
    }
}

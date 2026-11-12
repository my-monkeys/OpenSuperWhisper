import XCTest

@testable import OpenSuperWhisper
import OpenSuperWhisperCore

final class DictationReportTests: XCTestCase {

    private func draft(output: String = "Hello there.",
                       expected: String? = nil,
                       raw: String? = nil,
                       note: String = "",
                       language: String? = "fr",
                       translate: Bool = false,
                       timing: DictationTiming? = nil) -> DictationReportDraft {
        DictationReportDraft(note: note, modelUsed: "Parakeet Ultra", languageSetting: language,
                             translateToEnglish: translate, durationSeconds: 4, output: output,
                             expected: expected, rawOutput: raw, appVersion: "0.14.0 (63)", osVersion: "26.2",
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

    /// The output alone comes out the same on the maintainer's Mac; what it should have been is
    /// what says what went wrong.
    func testTheCorrectionFollowsTheOutput() {
        let message = DictationReport.message(for: draft(output: "Is it possible to make active T-mux pains more obvious?",
                                                         expected: "Is it possible to make active tmux panes more obvious?"),
                                              outputLimit: 2000, includeRaw: true)

        XCTAssertTrue(message.contains("output: Is it possible to make active T-mux pains more obvious?\n"
            + "expected: Is it possible to make active tmux panes more obvious?"))
    }

    func testNoExpectedLineWithoutACorrection() {
        XCTAssertFalse(DictationReport.message(for: draft(), outputLimit: 2000, includeRaw: true).contains("expected:"))
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

    /// The largest output a report can carry, with the timing line: the line costs its own
    /// length and never a character of the dictated text, and the result still fits the endpoint.
    func testAMaximalOutputFitsWithTheTimingLine() {
        var timing = DictationTiming()
        timing.totalMs = 4_300
        timing.transcribeMs = 1_200
        timing.cleanupMs = 600
        timing.transcribeAttempts = 2
        let output = String(repeating: "x", count: DictationReport.maxTextLength)

        let submission = DictationReport.submission(for: draft(output: output, timing: timing))

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertTrue(submission.message.contains("timing: total 4.3 s"),
                      "there is room for the line, so it goes")
        XCTAssertEqual(outputLine(in: submission.message)?.count,
                       "output: ".count + output.count,
                       "the whole output is sent; the timing line does not cost text")
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

    // MARK: - Long corrections

    func testTheChangedSpanKeepsSomeTextAroundTheChange() {
        let span = DictationReport.changedSpan(output: "I'll meet on Thursday at noon",
                                               expected: "I'll meet on Tuesday at noon", context: 5)

        XCTAssertEqual(span.output, "… on Thursday …")
        XCTAssertEqual(span.expected, "… on Tuesday …")
    }

    func testAChangeAtTheStartHasNoEllipsisThere() {
        let span = DictationReport.changedSpan(output: "Thursday works", expected: "Tuesday works", context: 20)

        XCTAssertEqual(span.output, "Thursday works")
        XCTAssertEqual(span.expected, "Tuesday works")
    }

    /// A long dictation cannot go out twice in full, and shortening keeps the start of each text:
    /// the correction near the end must still be in what is sent.
    func testALongCorrectionSendsTheChangedPart() {
        let opening = String(repeating: "We went over the roadmap again. ", count: 90)
        let output = opening + "Let's meet on Thursday at noon."
        let expected = opening + "Let's meet on Tuesday at noon."

        let submission = DictationReport.submission(for: draft(output: output, expected: expected))

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        let lines = submission.message.split(separator: "\n").map(String.init)
        let sentOutput = lines.first { $0.hasPrefix("output: ") }
        let sentExpected = lines.first { $0.hasPrefix("expected: ") }
        XCTAssertTrue(sentOutput?.contains("meet on Thursday at noon") == true)
        XCTAssertTrue(sentExpected?.contains("meet on Tuesday at noon") == true)
        XCTAssertTrue(sentOutput?.hasPrefix("output: …") == true, "only the part around the change goes")
    }

    /// When both fit, both go whole: a short report is read as it was dictated.
    func testAShortCorrectionSendsBothTextsWhole() {
        let submission = DictationReport.submission(for: draft(output: "Meet on Thursday.", expected: "Meet on Tuesday."))

        XCTAssertTrue(submission.message.contains("output: Meet on Thursday.\nexpected: Meet on Tuesday."))
    }
}

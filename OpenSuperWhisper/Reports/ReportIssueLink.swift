import Foundation
import OpenSuperWhisperCore

/// The prefilled "new issue" page for a report (#168). Opening it only fills GitHub's form in
/// the browser: nothing is posted until the user submits it there, and the audio is never part
/// of it (it would not fit in a link anyway; the zip export is for that).
enum ReportIssueLink {
    /// GitHub turns away longer "new issue" links, and some browsers cut them. The texts are
    /// shortened until the whole link fits under this.
    static let maxURLLength = 7_000
    private static let initialTextLimit = 2_000
    private static let minimumTextLimit = 80

    static func url(for report: TranscriptionReport, newIssue: URL = FeedbackLink.newIssue) -> URL {
        var limit = initialTextLimit
        var link = url(for: report, newIssue: newIssue, textLimit: limit)
        while link.absoluteString.count > maxURLLength, limit > minimumTextLimit {
            limit /= 2
            link = url(for: report, newIssue: newIssue, textLimit: limit)
        }
        return link
    }

    private static func url(for report: TranscriptionReport, newIssue: URL, textLimit: Int) -> URL {
        let query = "title=\(percentEncoded(title(for: report)))&body=\(percentEncoded(body(for: report, textLimit: textLimit)))"
        return URL(string: "\(newIssue.absoluteString)?\(query)")!
    }

    static func title(for report: TranscriptionReport) -> String {
        let model = report.modelUsed.map { " (\($0))" } ?? ""
        return "Transcription report: \(report.problem.issueLabel.lowercased())\(model)"
    }

    static func body(for report: TranscriptionReport, textLimit: Int = initialTextLimit) -> String {
        var lines = ["**What went wrong:** \(report.problem.issueLabel)"]
        if let shouldBe = report.shouldBe { lines.append("**Should be:** \(shortened(shouldBe, to: textLimit))") }
        if let writtenAs = report.writtenAs { lines.append("**Written as:** \(shortened(writtenAs, to: textLimit))") }
        if !report.comment.isEmpty {
            lines.append("")
            lines += shortened(report.comment, to: textLimit).components(separatedBy: .newlines).map { "> \($0)" }
        }
        lines += ["", "- Model: \(modelLine(for: report))"]
        if let language = report.languageSetting { lines.append("- Language setting: \(language)") }
        lines.append("- Length: \(String(format: "%.1f", report.duration)) s")
        lines.append("- Timing: \(timingLine(for: report))")
        lines.append("- App: \(report.appDetails)")
        lines.append("")
        if let raw = report.distinctRawText {
            lines += ["**Before cleanup** (the engine's text)"] + fenced(shortened(raw, to: textLimit)) + [""]
            lines += ["**Final text**"] + fenced(shortened(report.finalText, to: textLimit))
        } else {
            let note = report.rawText == nil ? "the text before cleanup was not kept" : "same as before cleanup"
            lines += ["**Final text** (\(note))"] + fenced(shortened(report.finalText, to: textLimit))
        }
        if let expected = report.expectedText {
            lines += ["", "**Should have written**"] + fenced(shortened(expected, to: textLimit))
        }
        lines += ["", "_The audio is not attached. It is in the zip exported from Reports in the app, if you want to add it._"]
        return lines.joined(separator: "\n")
    }

    private static func modelLine(for report: TranscriptionReport) -> String {
        let model = report.modelUsed ?? "unknown"
        return report.wasFallback ? "\(model) (local fallback, the server was unreachable)" : model
    }

    /// Where the wall-clock time went, in the same English the rest of the body uses. Inside the
    /// parentheses the unit is implied by the leading total; a stage that did not run is an em
    /// dash, which is a different fact from zero. The engine split is nested inside `transcribe`
    /// on purpose: both spans are measured within it, so listing them as siblings would read as
    /// a partition and double-count against the total.
    private static func timingLine(for report: TranscriptionReport) -> String {
        guard let timing = report.timing else { return "not measured" }
        let transcribe = timing.transcribeMs.map {
            "transcribe \(value($0)) [engine wait \(value(timing.engineWaitMs)), "
                + "model load \(value(timing.engineLoadMs))]"
        } ?? "transcribe —"
        let stages = [
            stage("finalize", timing.finalizeMs),
            stage("queue", timing.queueWaitMs),
            transcribe,
            stage("cleanup", timing.cleanupMs),
            stage("insert", timing.insertMs),
        ].joined(separator: ", ")
        let total = timing.totalMs.map { String(format: "%.1f", Double($0) / 1000) + " s" } ?? "—"
        var line = "total \(total) (\(stages))"
        if let attempts = timing.transcribeAttempts { line += " · attempts \(attempts)" }
        if let machine = timing.machine {
            line += " · thermal \(machine.thermalState) · low power \(machine.lowPowerMode ? "on" : "off")"
        }
        if let ending = report.ending { line += " · ended \(endingLabel(ending))" }
        line += " · measured at dictation time"
        return line
    }

    private static func stage(_ name: String, _ milliseconds: Int?) -> String {
        "\(name) \(value(milliseconds))"
    }

    private static func value(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return String(format: "%.1f", Double(milliseconds) / 1000)
    }

    /// The terminal point the data can support: a failure is known from the row's status, an
    /// insertion from a measured insertion. A completed row with no insertion is named as such,
    /// never guessed into a hand-off the report cannot distinguish.
    private static func endingLabel(_ ending: TranscriptionReport.Ending) -> String {
        switch ending {
        case .insertion: return "insertion"
        case .noInsertion: return "no insertion"
        case .failure: return "failure"
        }
    }

    /// A fence longer than any run of tildes in the text, so nothing in a dictation can close it.
    static func fenced(_ text: String) -> [String] {
        var longest = 0, run = 0
        for character in text {
            run = character == "~" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "~", count: max(3, longest + 1))
        return ["\(fence)text", text, fence]
    }

    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " […]"
    }

    /// Everything but the unreserved characters, "+" and "&" included: a query decoder reads a
    /// bare "+" as a space, and a bare "&" would end the body early.
    static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

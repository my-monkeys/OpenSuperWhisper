import Foundation
import OpenSuperWhisperCore

/// A dictation the person flagged as wrong, reduced to what diagnoses it, without the audio unless they add it.
///
/// Plain fields, not a `Recording`, so building the message and keeping it under the endpoint's
/// limit can be tested on their own. The audio stays on this Mac unless the person switches it on;
/// only what they chose to send when they tapped "report" goes out, and never where they were dictating.
struct DictationReportDraft: Equatable {
    /// What the person typed about what went wrong, if anything (e.g. "spoke French, got English").
    var note: String
    var modelUsed: String?
    /// The language the engine was set to: "auto", "en", "fr"… The whole point for the case where
    /// French audio comes back in English.
    var languageSetting: String?
    var translateToEnglish: Bool
    var durationSeconds: Int
    /// The text the dictation produced, after cleanup and style.
    var output: String
    /// The raw engine output, sent only when it differs from `output`, so a cleanup bug and an
    /// engine bug can be told apart.
    var rawOutput: String?
    var appVersion: String
    var osVersion: String
    /// Where the dictation's time went (#262). Nil when nothing was measured, which leaves the
    /// timing line out instead of sending a zero.
    var timing: DictationTiming? = nil
}

/// Builds the message and the submission a reported dictation sends to the feedback endpoint.
enum DictationReport {

    /// How much of the output text a report may carry. The rest is dropped before the raw text, so
    /// a very long dictation still sends its settings and the start of what it produced.
    static let maxTextLength = 2000

    static func message(for draft: DictationReportDraft, outputLimit: Int, includeRaw: Bool,
                        includeTiming: Bool = true) -> String {
        var lines = ["Dictation reported as wrong."]
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines.append(note) }
        lines.append("model: \(draft.modelUsed ?? "unknown")")
        lines.append("language: \(draft.languageSetting ?? "auto")"
            + (draft.translateToEnglish ? " · translate to English: on" : ""))
        lines.append("duration: \(draft.durationSeconds)s")
        if includeTiming, let timing = draft.timing, let line = timingLine(timing) { lines.append(line) }
        lines.append("output: \(String(draft.output.prefix(max(0, outputLimit))))")
        if includeRaw, let raw = draft.rawOutput, raw != draft.output {
            lines.append("raw: \(String(raw.prefix(max(0, outputLimit))))")
        }
        return lines.joined(separator: "\n")
    }

    /// "timing: total 4.3 s · transcribe 1.2 s · cleanup 0.6 s · attempts 1", each clause only
    /// when it was measured. Nil when the blob holds none of them, so no empty line is sent.
    private static func timingLine(_ timing: DictationTiming) -> String? {
        var parts: [String] = []
        if let total = timing.totalMs { parts.append("total " + seconds(total)) }
        if let transcribe = timing.transcribeMs { parts.append("transcribe " + seconds(transcribe)) }
        if let cleanup = timing.cleanupMs { parts.append("cleanup " + seconds(cleanup)) }
        if let attempts = timing.transcribeAttempts { parts.append("attempts \(attempts)") }
        guard !parts.isEmpty else { return nil }
        return "timing: " + parts.joined(separator: " · ")
    }

    private static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.1f", Double(milliseconds) / 1000) + " s"
    }

    /// A submission carrying the dictation's settings and text. The person's email is left blank:
    /// they can add one in the card, but a one-tap report does not ask for it. Trimmed to fit the
    /// endpoint, dropping the timing line first, then the raw text, then shortening the output.
    static func submission(for draft: DictationReportDraft, email: String = "") -> FeedbackSubmission {
        let details = "OpenSuperWhisper \(draft.appVersion) · macOS \(draft.osVersion)"
        func make(outputLimit: Int, includeRaw: Bool, includeTiming: Bool = true) -> FeedbackSubmission {
            FeedbackSubmission(kind: .bug,
                               message: message(for: draft, outputLimit: outputLimit,
                                                includeRaw: includeRaw, includeTiming: includeTiming),
                               email: email,
                               details: details)
        }

        let full = make(outputLimit: maxTextLength, includeRaw: true)
        if FeedbackSender.fitsLimits(full) { return full }

        // The timing line is diagnostic metadata: it may cost its own length and nothing else,
        // never a character of the dictated text, so it goes before the raw text is dropped or
        // the output is shortened.
        let withoutTiming = make(outputLimit: maxTextLength, includeRaw: true, includeTiming: false)
        if FeedbackSender.fitsLimits(withoutTiming) { return withoutTiming }

        let withoutRaw = make(outputLimit: maxTextLength, includeRaw: false, includeTiming: false)
        if FeedbackSender.fitsLimits(withoutRaw) { return withoutRaw }

        var outputLimit = maxTextLength
        while outputLimit > 0 {
            outputLimit /= 2
            let shorter = make(outputLimit: outputLimit, includeRaw: false, includeTiming: false)
            if FeedbackSender.fitsLimits(shorter) { return shorter }
        }
        return make(outputLimit: 0, includeRaw: false, includeTiming: false)
    }
}

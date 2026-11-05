import Foundation
import OpenSuperWhisperCore

/// Sends the text of a reported dictation to the feedback endpoint, the one-tap "a copy to the
/// developer" next to the local report (#168 follow-up). Text only: the audio and the full report
/// stay on this Mac, and only what the person already chose to report goes out.
enum DictationReportSender {

    /// Main-actor bound because it reads `RecordingStore.shared` by id before building the
    /// message; the network await below does not hold the actor.
    @MainActor
    static func send(recording: Recording, problem: TranscriptionReport.Problem?, comment: String) async throws {
        // Same re-read as the saved report: the card's copy predates the post-delivery timing
        // update, so sending it would omit `total` from the timing line. A read error reaches
        // the card's "Couldn't send — retry" state instead of sending stale numbers.
        let current = try await RecordingStore.shared.recordingForReport(recording)
        let submission = DictationReport.submission(for: draft(recording: current, problem: problem, comment: comment))
        try await FeedbackSender().send(submission)
    }

    static func draft(recording: Recording,
                      problem: TranscriptionReport.Problem?,
                      comment: String) -> DictationReportDraft {
        let note = [problem?.issueLabel, comment.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "0.0.0")"
            + " (\(info?["CFBundleVersion"] as? String ?? "0"))"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return DictationReportDraft(
            note: note,
            modelUsed: recording.modelUsed,
            languageSetting: AppPreferences.shared.whisperLanguage,
            translateToEnglish: AppPreferences.shared.translateToEnglish,
            durationSeconds: Int(recording.duration.rounded()),
            output: recording.transcription,
            rawOutput: recording.distinctOriginal,
            appVersion: version,
            osVersion: osString,
            timing: recording.timing)
    }
}

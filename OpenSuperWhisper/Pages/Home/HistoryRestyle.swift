import Foundation
import OpenSuperWhisperCore

/// Rewrites a dictation from the history in another writing style (#160). Only the AI cleanup
/// runs again, on the engine's own text that the row keeps, so nothing is transcribed twice.
@MainActor
enum HistoryRestyle {
    /// Whether a row can be rewritten: the cleanup has to be on for a style to change anything.
    static func isAvailable(for recording: Recording) -> Bool {
        AppPreferences.shared.aiPostProcessingEnabled && recording.status == .completed
            && !(recording.rawTranscription ?? recording.transcription)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The name a row keeps for the style its text was written in, nil when no style shaped it.
    static func label(for style: WritingStyle) -> String? {
        guard AppPreferences.shared.aiPostProcessingEnabled, !style.instructions.isEmpty else { return nil }
        return WritingStyleText.name(style)
    }

    /// The same steps a dictation takes after the engine: filler words, cleanup in the style,
    /// then snippets. No app rules: the row only knows the app by name.
    static func run(_ recording: Recording, in style: WritingStyle) async {
        let prefs = AppPreferences.shared
        let engineText = recording.rawTranscription ?? recording.transcription
        let cleanup = await LLMPostProcessor.processWithOutcome(prefs.cleanTranscription(engineText), bundleID: nil,
                                                                style: style.instructions)
        let text = prefs.expandSnippets(cleanup.text)
        do {
            try await RecordingStore.shared.restyle(recording, transcription: text, styleUsed: label(for: style),
                                                    cleanup: cleanup)
        } catch {
            IndicatorWindowManager.shared.flash(.error(String(localized: "Couldn't save the rewritten text")))
        }
    }
}

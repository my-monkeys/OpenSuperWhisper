import Foundation
import OpenSuperWhisperCore

/// Rewrites a dictation from the history in another writing style (#160). Only the AI cleanup
/// runs again, on the engine's own text that the row keeps, so nothing is transcribed twice.
@MainActor
enum HistoryRestyle {
    /// Whether a row can be rewritten: AI cleanup has to be on somewhere, globally or for one app,
    /// for an engine to be set up. The row's own app does not matter, since a rewrite is asked for.
    static func isAvailable(for recording: Recording) -> Bool {
        AppPreferences.shared.cleanupOnSomewhere && recording.status == .completed
            && !(recording.rawTranscription ?? recording.transcription)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The name a row keeps for the style its text was written in, nil when no style shaped it:
    /// the cleanup did not run, or the style added nothing to it.
    static func label(for style: WritingStyle, cleanedUp: Bool) -> String? {
        guard cleanedUp, !style.instructions.isEmpty else { return nil }
        return WritingStyleText.name(style)
    }

    /// What the regenerate panel asks of one pass: the style, the backend and, for Ollama or
    /// Remote, the model id to try, and an instruction for this pass only.
    struct Request {
        var style: WritingStyle
        /// nil → the backend dictations use.
        var backend: String? = nil
        var model: String? = nil
        var extraInstruction = ""
    }

    /// The same steps a dictation takes after the engine: filler words, cleanup in the style,
    /// then snippets. No app rules: the row only knows the app by name. The cleanup runs whatever
    /// the global switch says, since this pass is the one thing asked for.
    static func run(_ recording: Recording, _ request: Request) async {
        let prefs = AppPreferences.shared
        let engineText = recording.rawTranscription ?? recording.transcription
        let backend = request.backend.map { LLMPostProcessor.backend($0, model: request.model) }
        let cleanup = await LLMPostProcessor.processWithOutcome(
            prefs.cleanTranscription(engineText), bundleID: nil, style: request.style.instructions,
            extraInstruction: request.extraInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
            generalCleanup: true, backend: backend)
        let text = prefs.expandSnippets(cleanup.text)
        do {
            try await RecordingStore.shared.restyle(recording, transcription: text,
                                                    styleUsed: label(for: request.style, cleanedUp: true),
                                                    cleanup: cleanup)
        } catch {
            IndicatorWindowManager.shared.flash(.error(String(localized: "Couldn't save the rewritten text")))
        }
    }
}

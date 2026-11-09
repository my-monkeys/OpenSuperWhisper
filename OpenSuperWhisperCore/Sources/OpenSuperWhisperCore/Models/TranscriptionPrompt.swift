import Foundation

/// What the transcriber is told to expect before it hears anything.
///
/// Three things can feed it and they are not interchangeable: the prompt the user wrote, the
/// spellings their dictionary insists on, and the sentence they were in the middle of writing.
/// Assembled here rather than in the engine so the ordering is one decision in one place, and
/// so it can be tested without a model.
enum TranscriptionPrompt {

    /// Ordered so that the text nearest the dictation comes last.
    ///
    /// Whisper conditions on the prompt as though it were the words immediately preceding the
    /// audio, so what the user was in the middle of writing belongs at the end, next to what
    /// they are about to say. The standing prompt is background and goes first.
    static func combined(userPrompt: String,
                         dictionaryBoost: String,
                         surroundingText: String?) -> String? {
        let parts = [userPrompt, dictionaryBoost, surroundingText ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// Whether the prompt may be carried into every 30 s window rather than only the first.
    ///
    /// whisper.cpp builds each window's prompt from at most half the model's text context: the
    /// carried prompt first, then whatever room is left for what was just said. A prompt that
    /// takes more than half of that budget leaves the rolling history almost nothing, and the
    /// text of the previous window stops conditioning the next one. Past it the prompt still
    /// conditions the first window, which is where the user's vocabulary matters most.
    static func canCarry(promptTokens: Int, textContext: Int) -> Bool {
        promptTokens > 0 && promptTokens <= max(1, (textContext / 2 - 1) / 2)
    }

    /// The surrounding text to use, or nil when the setting is off.
    ///
    /// Split out from `combined` because the decision to read someone's document is worth
    /// naming, and because a caller that forgets the flag should get nothing rather than
    /// silently get the text.
    static func surroundingText(enabled: Bool, captured: String?) -> String? {
        guard enabled, let captured, !captured.isEmpty else { return nil }
        return captured
    }
}

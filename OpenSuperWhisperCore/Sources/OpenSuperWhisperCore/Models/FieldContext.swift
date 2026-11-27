import Foundation

/// The focused field's context an engine is allowed to see, for one transcription (#89).
///
/// Internal on purpose: it never crosses the module boundary. `TranscriptionService` builds it
/// after the engine is known, and only an engine that conforms to a context protocol can be
/// handed it — the remote engine cannot receive it even by mistake.
///
/// An enum rather than two optional members (`prose: String?`, `terms: [String]?`). With two
/// optionals an implementation could fill both and still type-check, which would run the spelling
/// pass for Whisper — a cost this shape exists to make impossible, the same way the conforming
/// cast makes the remote exclusion structural.
enum FieldContext {
    /// Free text, for an engine that conditions on an initial prompt.
    case prose(String)
    /// Terms, for an engine biased toward a vocabulary list.
    case terms([String])

    /// Whether `engine` can be handed this value — the same check the dispatch cast makes, asked
    /// before the value is chosen rather than after. Used when a context was resolved ahead of
    /// the engine gate, against the engine that was loaded then: if a reload replaced it in the
    /// meantime, the value is discarded and resolved again rather than silently dropped.
    func matches(_ engine: TranscriptionEngine) -> Bool {
        switch self {
        case .prose: return engine is ProseContextEngine
        case .terms: return engine is TermContextEngine
        }
    }
}

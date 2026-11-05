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
}

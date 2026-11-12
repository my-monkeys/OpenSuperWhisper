import Foundation

/// What one cleanup pass did to a dictation, so the UI can say so instead of leaving the user to
/// compare raw and final text: a pass that succeeded may legitimately change nothing.
public struct CleanupOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Neither cleanup nor app formatting is on, or there was nothing to send (empty text,
        /// no prompt to run).
        case notRun
        /// The pass ran and its output was used. The text may equal the input.
        case cleaned(model: String)
        /// The pass was due but the raw text was used: backend not ready, network or HTTP error,
        /// unreadable reply, or a reply the guards rejected.
        case failed(model: String, reason: String)
    }

    public let text: String
    public let status: Status

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }

    /// The model to record on the dictation: set whenever the pass ran or was attempted.
    public var model: String? {
        switch status {
        case .notRun: return nil
        case .cleaned(let model), .failed(let model, _): return model
        }
    }

    /// Why the raw text was used, set only for a failed pass.
    public var failureReason: String? {
        if case .failed(_, let reason) = status { return reason }
        return nil
    }
}

/// A reply that must not stand in for the dictation, whichever backend wrote it. Worded for the
/// same one-line notice as `CleanupHTTPError`.
enum CleanupReplyError: LocalizedError, Equatable {
    /// The model stopped on a length limit, not because it had finished: the end of the dictation
    /// is missing from the reply.
    case cutOff
    /// The instructions and the dictation do not fit in what the model can read at once.
    case tooLong

    var errorDescription: String? {
        switch self {
        case .cutOff: return "Reply cut off before the end"
        case .tooLong: return "Dictation too long for the model"
        }
    }
}

/// A non-2xx answer from a cleanup server, worded for a one-line notice: "401 Invalid API key".
struct CleanupHTTPError: LocalizedError, Equatable {
    let status: Int
    let message: String?

    init(status: Int, body: Data) {
        self.status = status
        self.message = Self.serverMessage(in: body)
    }

    var errorDescription: String? {
        message.map { "\(status) \($0)" } ?? "HTTP \(status)"
    }

    static let maxMessageLength = 120

    /// The server's own explanation: OpenAI-style `{"error":{"message":"…"}}` (OpenRouter, Groq and
    /// OpenAI all answer this way), Ollama's `{"error":"…"}`, or a bare `{"message":"…"}`. Squeezed
    /// to one short line because it ends up in a bubble and a table row.
    static func serverMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw: String?
        if let error = json["error"] as? [String: Any] {
            raw = error["message"] as? String
        } else {
            raw = (json["error"] as? String) ?? (json["message"] as? String)
        }
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > maxMessageLength ? String(line.prefix(maxMessageLength - 1)) + "…" : line
    }
}

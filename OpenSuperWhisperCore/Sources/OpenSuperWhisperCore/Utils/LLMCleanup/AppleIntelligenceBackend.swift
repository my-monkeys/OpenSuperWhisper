import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device model can clean up a dictation, and if not, why. The settings menu
/// greys the engine out with the reason, and an unavailable model at dictation time falls back
/// to the raw text like any failing backend.
public enum AppleIntelligenceAvailability: Equatable, Sendable {
    case available
    /// Older than macOS 26, an Intel Mac, or a Mac Apple doesn't offer Apple Intelligence on.
    case unsupportedMac
    /// Apple Intelligence is switched off in System Settings.
    case turnedOff
    /// Turned on, but the model is still downloading or preparing.
    case modelNotReady
    /// The model runs, but not in this language (a Whisper language code).
    case unsupportedLanguage(String)
}

/// The on-device model as the cleanup backend uses it. Behind a protocol so selection, the
/// availability mapping, the context guard and the fallback are tested without the real model,
/// which CI runners may not have.
public protocol OnDeviceLanguageModel: Sendable {
    var availability: AppleIntelligenceAvailability { get }
    /// Whether the model handles text in this Whisper language code ("en", "fr"…).
    func supportsLanguage(_ code: String) -> Bool
    /// Tokens the model can hold at once: instructions, the dictation and the reply together.
    var contextSize: Int { get }
    func tokenCount(of text: String) async -> Int
    func respond(instructions: String, prompt: String) async throws -> String
}

/// Entry point to Apple's on-device model: the system one where FoundationModels exists, nothing
/// elsewhere.
public enum AppleIntelligence {
    private static let replacement = OSAllocatedUnfairLock<(any OnDeviceLanguageModel)?>(initialState: nil)

    /// The model the backend talks to. Nil before macOS 26 and wherever FoundationModels isn't
    /// in the SDK.
    static var model: (any OnDeviceLanguageModel)? {
        replacement.withLock { $0 } ?? systemModel
    }

    private static var systemModel: (any OnDeviceLanguageModel)? {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return SystemOnDeviceModel.shared }
#endif
        return nil
    }

    /// Availability for dictating in `language`, a Whisper code. "auto", empty or nil skips the
    /// language check: the detected language isn't known until the dictation is transcribed.
    public static func availability(language: String?) -> AppleIntelligenceAvailability {
        availability(of: model, language: language)
    }

    static func availability(of model: (any OnDeviceLanguageModel)?,
                             language: String?) -> AppleIntelligenceAvailability {
        guard let model else { return .unsupportedMac }
        let status = model.availability
        guard status == .available else { return status }
        if let language, !language.isEmpty, language != "auto", !model.supportsLanguage(language) {
            return .unsupportedLanguage(language)
        }
        return .available
    }

    /// Token count for a model too old to count them itself (macOS 26.0 to 26.3). Pessimistic on
    /// purpose, because overestimating only sends a borderline dictation back raw while
    /// underestimating overflows the context: a third of the characters for spaced scripts, where
    /// the tokenizer averages closer to four per token, and one per character for Han, kana and
    /// Hangul.
    static func estimatedTokenCount(_ text: String) -> Int {
        if LLMPostProcessor.isDenseScript(text) { return text.count }
        return (text.count + 2) / 3
    }

    /// Room for the chat template's role markers around the instructions and the dictation.
    static let templateOverheadTokens = 64

    /// Whether one cleanup pass fits the context window. The reply is about as long as the
    /// dictation it rewrites and shares the same window, so the dictation is counted twice.
    static func fitsContext(instructionTokens: Int, textTokens: Int, contextSize: Int) -> Bool {
        instructionTokens + 2 * textTokens + templateOverheadTokens <= contextSize
    }

#if DEBUG
    /// Tests stand in for the system model; nil puts it back. Returns the replacement it undid.
    @discardableResult
    static func replaceModelForTesting(_ model: (any OnDeviceLanguageModel)?) -> (any OnDeviceLanguageModel)? {
        replacement.withLock { current in
            let previous = current
            current = model
            return previous
        }
    }
#endif
}

/// LLM cleanup on Apple's on-device foundation model (macOS 26, Apple Silicon, Apple Intelligence
/// on). Nothing to download and nothing leaves the Mac, but the window is small (about 4k
/// tokens), so a dictation that would not fit is sent back raw rather than truncated.
struct AppleIntelligenceBackend: LLMCleanupBackend, CustomStringConvertible {
    enum Failure: LocalizedError, Equatable {
        case unavailable(AppleIntelligenceAvailability)
        case exceedsContext(tokens: Int, contextSize: Int)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple Intelligence is not available"
            case .exceedsContext: return "Dictation too long for Apple Intelligence"
            }
        }
    }

    let model: (any OnDeviceLanguageModel)?

    var isReady: Bool { availability == .available }

    /// The language check is the settings menu's job: a dictation in a language the model can't
    /// handle fails in `respond` and falls back like any other error.
    var availability: AppleIntelligenceAvailability {
        AppleIntelligence.availability(of: model, language: nil)
    }

    var modelLabel: String { "Apple Intelligence" }

    var description: String { "Apple Intelligence (\(availability))" }

    func generate(system: String, user: String) async throws -> String {
        guard let model, availability == .available else { throw Failure.unavailable(availability) }
        let instructionTokens = await model.tokenCount(of: system)
        let textTokens = await model.tokenCount(of: user)
        let contextSize = model.contextSize
        guard AppleIntelligence.fitsContext(instructionTokens: instructionTokens, textTokens: textTokens,
                                            contextSize: contextSize)
        else {
            let needed = instructionTokens + 2 * textTokens + AppleIntelligence.templateOverheadTokens
            throw Failure.exceedsContext(tokens: needed, contextSize: contextSize)
        }
        return try await model.respond(instructions: system, prompt: user)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
extension AppleIntelligenceAvailability {
    init(_ system: SystemLanguageModel.Availability) {
        switch system {
        case .available: self = .available
        case .unavailable(.appleIntelligenceNotEnabled): self = .turnedOff
        case .unavailable(.modelNotReady): self = .modelNotReady
        // `deviceNotEligible`, and any reason a later SDK adds: none of them is something the
        // user can fix from here.
        default: self = .unsupportedMac
        }
    }
}

/// The real model, with the guardrails Apple provides for transforming text the user wrote
/// rather than generating new text: every refusal is a dictation pasted without cleanup.
@available(macOS 26.0, iOS 26.0, *)
final class SystemOnDeviceModel: OnDeviceLanguageModel {
    static let shared = SystemOnDeviceModel()

    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    var availability: AppleIntelligenceAvailability { AppleIntelligenceAvailability(model.availability) }

    func supportsLanguage(_ code: String) -> Bool {
        model.supportsLocale(Locale(identifier: code))
    }

    var contextSize: Int { model.contextSize }

    func tokenCount(of text: String) async -> Int {
        if #available(macOS 26.4, iOS 26.4, *), let count = try? await model.tokenCount(for: text) {
            return count
        }
        return AppleIntelligence.estimatedTokenCount(text)
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        // Temperature 0 rather than greedy sampling: the sampling option is labelled `sampling:` in
        // the Xcode 26 SDK and `samplingMode:` in Xcode 27, while `temperature:` is the same in both.
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
        return response.content
    }
}
#endif

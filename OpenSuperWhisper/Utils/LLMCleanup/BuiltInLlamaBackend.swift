import Foundation

/// Built-in LLM cleanup backend: a small GGUF model run locally via llama.cpp (`LlamaContext`),
/// with no external server. The model downloads on first use (`LLMModelManager`); the inference
/// context loads lazily and is cached for the process lifetime (~1 GB resident). This is the
/// zero-setup alternative to `OllamaBackend`.
final class BuiltInLlamaBackend: LLMCleanupBackend {
    static let shared = BuiltInLlamaBackend()

    enum BuiltInLlamaError: Error { case modelNotReady }

    private let manager = LLMModelManager.shared
    private let loadLock = NSLock()
    private var context: LlamaContext?

    private init() {}

    /// Ready once the default model is on disk. The context itself loads on first `generate`.
    var isReady: Bool { manager.isDefaultModelDownloaded() }

    /// Loads the model context once, lazily. Heavy (~1 GB) so it's cached and reused.
    private func ensureContext() -> LlamaContext? {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let context { return context }
        guard manager.isDefaultModelDownloaded() else { return nil }
        let path = manager.localURL(for: LLMModelManager.defaultModel.fileName).path
        context = LlamaContext(modelPath: path)
        return context
    }

    func generate(system: String, user: String) async throws -> String {
        guard let ctx = ensureContext() else { throw BuiltInLlamaError.modelNotReady }
        // Inference is synchronous and compute-heavy; `LLMPostProcessor.process` already runs
        // this off the main actor (from the post-transcription Task), so blocking here is fine.
        return ctx.generate(system: system, user: user)
    }
}

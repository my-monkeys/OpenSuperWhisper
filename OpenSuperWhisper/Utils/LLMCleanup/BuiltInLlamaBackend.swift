import Foundation
import WhisperCore

/// Built-in LLM cleanup backend: a small GGUF model run locally via llama.cpp (`LlamaContext`),
/// with no external server. The model downloads on first use (`LLMModelManager`); the inference
/// context loads lazily, is reused by later dictations, and is released again after
/// `idleUnloadDelay` without work. This is the zero-setup alternative to `OllamaBackend`.
///
/// Threading: `llama_context` is not thread-safe and two transcriptions CAN overlap (a hotkey
/// dictation and a file-drop/rerun pass run on different queues), so every touch of `context` —
/// loading, inference and the idle release — happens on `inferenceQueue`, a serial queue. That
/// also keeps ~1s–minutes of synchronous inference off Swift concurrency's cooperative pool.
final class BuiltInLlamaBackend: LLMCleanupBackend {
    static let shared = BuiltInLlamaBackend()

    enum BuiltInLlamaError: Error { case modelNotReady }

    /// Release the inference context (~1.2 GB resident, model + KV cache) after this long with no
    /// cleanup. An occasional dictation shouldn't hold a second model in RAM next to Whisper's own
    /// ~1 GB for the whole session; a burst of dictations still shares one load.
    private static let idleUnloadDelay: TimeInterval = 5 * 60

    private let manager = LLMModelManager.shared
    private let inferenceQueue = DispatchQueue(
        label: "fr.my-monkey.opensuperwhisper.llm-inference", qos: .userInitiated)

    /// Owned by `inferenceQueue` — never read or written from anywhere else.
    private var context: LlamaContext?
    private var idleUnloadWork: DispatchWorkItem?

    private init() {}

    /// Ready once the default model is on disk. The context itself loads on first `generate`.
    var isReady: Bool { manager.isDefaultModelDownloaded() }

    /// A 1.5B model is the one that can wander off the transform-only contract, so this is the
    /// backend whose output gets the length-ratio sanity check.
    var enforcesLengthRatio: Bool { true }

    /// Loads the model ahead of first use, so the first cleanup doesn't pay the multi-second load.
    /// Called from Settings when the built-in backend is selected or its model finishes
    /// downloading — the user is right there, and the idle release reclaims the RAM if they leave.
    func preload() {
        guard isReady else { return }
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            _ = self.loadContextOnQueue()
            self.scheduleIdleUnloadOnQueue()
        }
    }

    func generate(system: String, user: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self, let ctx = self.loadContextOnQueue() else {
                    continuation.resume(throwing: BuiltInLlamaError.modelNotReady)
                    return
                }
                let output = ctx.generate(system: system, user: user)
                self.scheduleIdleUnloadOnQueue()
                continuation.resume(returning: output)
            }
        }
    }

    // MARK: - inferenceQueue-confined state

    /// Returns the cached context, loading it (~1 GB) if needed. Must run on `inferenceQueue`.
    private func loadContextOnQueue() -> LlamaContext? {
        idleUnloadWork?.cancel()
        idleUnloadWork = nil
        if let context { return context }
        guard manager.isDefaultModelDownloaded() else { return nil }
        let path = manager.localURL(for: LLMModelManager.defaultModel.fileName).path
        context = LlamaContext(modelPath: path)
        return context
    }

    /// (Re)arms the idle release. Must run on `inferenceQueue`; the release itself runs there too,
    /// so it can never land while a generation is in flight.
    private func scheduleIdleUnloadOnQueue() {
        idleUnloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.context = nil          // deinit frees the llama model + KV cache
            self.idleUnloadWork = nil
        }
        idleUnloadWork = work
        inferenceQueue.asyncAfter(deadline: .now() + Self.idleUnloadDelay, execute: work)
    }
}

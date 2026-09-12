import Foundation

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
    /// Which GGUF `context` was loaded from, so a model switch can be noticed. Also
    /// `inferenceQueue`-confined.
    private var loadedFileName: String?

    private init() {}

    /// The model the user picked in Settings.
    private var selectedModel: LLMModelDescriptor {
        LLMModelManager.model(fileName: AppPreferences.shared.builtInModelFileName)
    }

    /// Ready once the selected model is on disk. The context itself loads on first `generate`.
    var isReady: Bool { manager.isModelDownloaded(name: selectedModel.fileName) }

    /// Even the larger built-in model is small next to a hosted one, so this backend keeps the
    /// length-ratio sanity check on its output.
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

    /// Returns the cached context, loading it if needed. Must run on `inferenceQueue`.
    ///
    /// A context is only reused while it belongs to the selected model: switching models in
    /// Settings otherwise keeps answering from the previously loaded GGUF until the idle release
    /// happens to fire, which looks exactly like the switch having no effect.
    private func loadContextOnQueue() -> LlamaContext? {
        idleUnloadWork?.cancel()
        idleUnloadWork = nil
        let model = selectedModel
        if let context, loadedFileName == model.fileName { return context }
        guard manager.isModelDownloaded(name: model.fileName) else { return nil }
        context = LlamaContext(modelPath: manager.localURL(for: model.fileName).path)
        loadedFileName = context == nil ? nil : model.fileName
        return context
    }

    /// (Re)arms the idle release. Must run on `inferenceQueue`; the release itself runs there too,
    /// so it can never land while a generation is in flight.
    private func scheduleIdleUnloadOnQueue() {
        idleUnloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.context = nil          // deinit frees the llama model + KV cache
            self.loadedFileName = nil
            self.idleUnloadWork = nil
        }
        idleUnloadWork = work
        inferenceQueue.asyncAfter(deadline: .now() + Self.idleUnloadDelay, execute: work)
    }
}

import AVFoundation
import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    /// One-permit gate serializing every transcription across the whole app. See the note in
    /// `transcribeAudio` — the engines share one non-thread-safe context. (parallel-recording #2)
    private static let engineGate = AsyncSemaphore(1)

    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    @Published private(set) var engineError: String?

    var isEngineReady: Bool {
        currentEngine != nil && !isLoading
    }

    private var currentEngine: TranscriptionEngine?
    private var loadedEngineKind: String?
    private var totalDuration: Float = 0.0

    /// The model that actually produced the most recent transcription, and whether it
    /// came from the remote local-fallback. Read by the recording-save paths so history
    /// shows the real model (and flags fallbacks). Set on the main actor per run.
    private(set) var lastUsedModel: DictationModelOption?
    private(set) var lastUsedFallback = false
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    
    init() {
        // Engines load lazily on first transcription (see ensureEngineLoaded), so
        // merely selecting an engine in Settings — or launching the app — never
        // triggers a model download. The download happens only when you actually
        // transcribe with that engine.
    }

    func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    /// Initialize the engine matching the current preference if it isn't already
    /// active. Called lazily from transcribeAudio, so selecting an engine in
    /// Settings only records the choice — the model isn't downloaded/loaded until
    /// you actually transcribe with it. Heavy work runs off the main actor.
    private func ensureEngineLoaded() async {
        let selectedEngine = AppPreferences.shared.selectedEngine
        if currentEngine != nil, loadedEngineKind == selectedEngine { return }

        isLoading = true
        engineError = nil
        print("Loading engine: \(selectedEngine)")

        let result = await Task.detached(priority: .userInitiated) { () -> Result<TranscriptionEngine?, Error> in
            let engine: TranscriptionEngine?

            if selectedEngine == "fluidaudio" {
                engine = await FluidAudioEngine()
            } else if selectedEngine == "sensevoice" {
#if arch(arm64)
                engine = SenseVoiceEngine()
#else
                // SenseVoice (sherpa-onnx/onnxruntime) ships arm64-only; fall back on Intel.
                engine = await WhisperEngine()
#endif
            } else if selectedEngine == "remote" {
                engine = RemoteEngine()
            } else if selectedEngine == "apple" {
#if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    engine = AppleSpeechEngine()
                } else {
                    // A pref synced from a newer machine; the catalog never offers
                    // "apple" here, so quietly fall back.
                    engine = await WhisperEngine()
                }
#else
                engine = await WhisperEngine()
#endif
            } else {
                engine = await WhisperEngine()
            }

            do {
                try await engine?.initialize()
                return .success(engine)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let engine):
            currentEngine = engine
            loadedEngineKind = (engine != nil) ? selectedEngine : nil
            print("Engine loaded: \(selectedEngine)")
        case .failure(let error):
            currentEngine = nil
            loadedEngineKind = nil
            engineError = "Failed to load engine: \(error.localizedDescription)"
            print("Failed to load engine: \(error)")
        }
        isLoading = false
    }

    /// Invalidate the active engine so the next transcription re-initializes it
    /// (used when the engine selection or model changes). Intentionally does NOT
    /// load or download anything — that's deferred to next use. Clears any stale
    /// load error, since the invalidated engine gets a fresh attempt next time.
    func reloadEngine() {
        currentEngine = nil
        loadedEngineKind = nil
        engineError = nil
    }
    
    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }

    /// Temporarily switch to `option` for one transcription and return a closure that restores the
    /// previous engine/model. No-op (returns an empty closure) when `option` is nil or already the
    /// active model. Mirrors `TranscriptionQueue.applyModelOverride`, but is called from inside
    /// `transcribeAudio`'s serialization gate so the swap can't leak to a concurrent caller.
    private func applyOneOffModel(_ option: DictationModelOption?) -> () -> Void {
        guard let option else { return {} }
        let current = ModelCatalog.activeOption()
        if current?.engine == option.engine && current?.identifier == option.identifier { return {} }

        let prefs = AppPreferences.shared
        let previousEngine = prefs.selectedEngine
        let previousWhisper = prefs.selectedWhisperModelPath
        let previousFluid = prefs.fluidAudioModelVersion
        let previousRemote = prefs.remoteServerModel

        prefs.selectedEngine = option.engine
        switch option.engine {
        case "whisper": prefs.selectedWhisperModelPath = option.identifier
        case "fluidaudio": prefs.fluidAudioModelVersion = option.identifier
        case "remote": prefs.remoteServerModel = option.identifier
        default: break
        }
        reloadEngine()

        return {
            prefs.selectedEngine = previousEngine
            prefs.selectedWhisperModelPath = previousWhisper
            prefs.fluidAudioModelVersion = previousFluid
            prefs.remoteServerModel = previousRemote
            self.reloadEngine()
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings, modelOverride: DictationModelOption? = nil) async throws -> String {
        // Serialize every transcription across the app (dictation pipeline, file-drop queue,
        // reruns, CLI): the engines share one non-thread-safe context (e.g. whisper.cpp) and this
        // object's per-run state (isTranscribing/progress/lastUsedModel). Two overlapping calls
        // would crash or corrupt output. (parallel-recording #2)
        await Self.engineGate.wait()
        // Apply a per-call model INSIDE the gate — the clip was recorded under this model, but a
        // later recording may since have switched the global one — so it can't leak to a concurrent
        // caller, and restore it before releasing. No-op when nil or already active. (#model-snapshot)
        let restoreModel = applyOneOffModel(modelOverride)
        defer {
            restoreModel()
            Task { await Self.engineGate.signal() }
        }

        await MainActor.run {
            self.progress = 0.0
            self.conversionProgress = 0.0
            self.isConverting = true
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false
        }
        
        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.isConverting = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }
        
        let durationInSeconds: Float = await (try? Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            return Float(CMTimeGetSeconds(duration))
        }.value) ?? 0.0
        
        await MainActor.run {
            self.totalDuration = durationInSeconds
        }

        return try await transcribe(url: url, settings: settings, fallbackModel: nil)
    }

    /// Load the appropriate engine and transcribe. On a fallback-worthy remote error
    /// (server unreachable / 5xx after retries), re-runs once with the configured local
    /// fallback model. Recursive by design: the `fallbackModel != nil` attempt is
    /// guarded out of the catch (`fallbackModel == nil`), so it can never loop.
    private func transcribe(url: URL, settings: Settings, fallbackModel: DictationModelOption?) async throws -> String {
        let engine: TranscriptionEngine
        if let fallbackModel {
            engine = try await makeEngine(for: fallbackModel)
            lastUsedModel = fallbackModel
            lastUsedFallback = true
        } else {
            // Lazily initialize the selected engine on first use (downloads a local
            // model only now, never on mere engine selection in Settings).
            await ensureEngineLoaded()
            guard let loaded = currentEngine else {
                throw TranscriptionError.contextInitializationFailed
            }
            engine = loaded
            lastUsedModel = ModelCatalog.activeOption()
            lastUsedFallback = false
        }

        do {
            return try await runOnEngine(engine, url: url, settings: settings)
        } catch let error where fallbackModel == nil && Self.shouldUseFallback(for: error) {
            guard AppPreferences.shared.remoteFallbackEnabled,
                  AppPreferences.shared.selectedEngine == "remote",
                  let fallback = AppPreferences.shared.remoteFallbackModel else {
                throw error
            }
            print("Remote transcription failed (\(error)); falling back to local model \(fallback.displayName)")
            return try await transcribe(url: url, settings: settings, fallbackModel: fallback)
        }
    }

    /// Run one transcription on a specific engine: wire its progress callback, run it
    /// off the main actor, and honor cancellation. Any engine error propagates so the
    /// caller (`transcribe`) can decide whether to fall back.
    private func runOnEngine(_ engine: TranscriptionEngine, url: URL, settings: Settings) async throws -> String {
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        } else if let remoteEngine = engine as? RemoteEngine {
            remoteEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()

            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            guard !cancelled else { throw CancellationError() }

            let result = try await engine.transcribeAudio(url: url, settings: settings)

            try Task.checkCancellation()

            let finalCancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }

            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = result
                self.progress = 1.0
            }

            guard !finalCancelled else { throw CancellationError() }

            return result
        }

        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
            }
            throw TranscriptionError.processingFailed
        }
    }

    /// Build + initialize an engine for a specific model (only for the remote
    /// local-fallback), without touching the global engine/model prefs. Runs the load
    /// off the main actor, like `ensureEngineLoaded`.
    private func makeEngine(for option: DictationModelOption) async throws -> TranscriptionEngine {
        try await Task.detached(priority: .userInitiated) { () -> TranscriptionEngine in
            let engine: TranscriptionEngine
            switch option.engine {
            case "fluidaudio":
                engine = await FluidAudioEngine(versionOverride: option.identifier)
            case "apple":
#if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    engine = AppleSpeechEngine()
                } else {
                    engine = await WhisperEngine()
                }
#else
                engine = await WhisperEngine()
#endif
            case "sensevoice":
#if arch(arm64)
                engine = SenseVoiceEngine()
#else
                engine = await WhisperEngine(modelPathOverride: option.identifier)
#endif
            default: // "whisper"
                engine = await WhisperEngine(modelPathOverride: option.identifier)
            }
            try await engine.initialize()
            return engine
        }.value
    }

    /// Whether a failed remote transcription should retry on the local fallback: only
    /// "can't use the server" errors (unreachable / 5xx after retries) — never auth or a
    /// real client 4xx that a local model wouldn't fix. Pure → `nonisolated` + testable.
    nonisolated static func shouldUseFallback(for error: Error) -> Bool {
        guard let remote = error as? RemoteError else { return false }
        switch remote {
        case .network:
            return true
        case .api(let status, _):
            return (500...599).contains(status)
        case .missingAPIKey, .invalidAPIKey:
            return false
        }
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}

/// Minimal async counting semaphore. Used as a 1-permit mutex to serialize transcriptions across
/// the app (see `TranscriptionService.transcribeAudio`). Correct under actor reentrancy: `signal`
/// hands the permit directly to the first waiter instead of bumping the count, so a waiter resumed
/// by `signal` stays mutually exclusive with everyone else.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int = 1) { self.permits = permits }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()   // hand the held permit straight to the next waiter
        } else {
            permits += 1
        }
    }
}

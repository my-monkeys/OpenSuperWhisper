import AVFoundation
import Foundation

/// Platform gates that decide engine fallback. Tests inject explicit values to reach
/// every mapping decision; production call sites use `.current`, which evaluates the
/// same compile-time/runtime truth the inline chain did (default arg → per call).
struct EnginePlatformGates {
    var supportsSenseVoice: Bool
    var supportsAppleSpeech: Bool

    static var current: EnginePlatformGates {
        var gates = EnginePlatformGates(supportsSenseVoice: false, supportsAppleSpeech: false)
#if os(macOS) && arch(arm64)
        gates.supportsSenseVoice = true
#endif
#if os(macOS) && canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            gates.supportsAppleSpeech = true
        }
#endif
        return gates
    }
}

@MainActor
public class TranscriptionService: ObservableObject {
    public static let shared = TranscriptionService()
    
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var transcribedText = ""
    @Published public private(set) var currentSegment = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var progress: Float = 0.0
    @Published public private(set) var isConverting = false
    @Published public private(set) var conversionProgress: Float = 0.0
    @Published public private(set) var engineError: String?

    public var isEngineReady: Bool {
        currentEngine != nil && !isLoading
    }

    private var currentEngine: TranscriptionEngine?
    private var loadedEngineKind: String?
    private var totalDuration: Float = 0.0

    /// The model that actually produced the most recent transcription, and whether it
    /// came from the remote local-fallback. Read by the recording-save paths so history
    /// shows the real model (and flags fallbacks). Set on the main actor per run.
    public private(set) var lastUsedModel: DictationModelOption?
    public private(set) var lastUsedFallback = false
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    
    init() {
        // Engines load lazily on first transcription (see ensureEngineLoaded), so
        // merely selecting an engine in Settings — or launching the app — never
        // triggers a model download. The download happens only when you actually
        // transcribe with that engine.
    }

    public func cancelTranscription() {
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

        let result = await Task.detached(priority: .userInitiated) { () -> Result<TranscriptionEngine, Error> in
            let engine = await Self.makeEngine(selectedEngine: selectedEngine)

            do {
                try await engine.initialize()
                return .success(engine)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let engine):
            currentEngine = engine
            loadedEngineKind = selectedEngine
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
    public func reloadEngine() {
        currentEngine = nil
        loadedEngineKind = nil
        engineError = nil
    }
    
    public func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    public func transcribeAudio(url: URL, settings: Settings) async throws -> String {
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

    /// Pure engine-kind mapping for the selected-engine preference: preference string
    /// in, un-initialized engine out. Construction only — the caller initializes inside
    /// the same detached task, exactly as the inline chain did. Pure → `nonisolated` + testable.
    /// Every arm returns an engine (default arm is Whisper), so the return is non-optional.
    nonisolated static func makeEngine(selectedEngine: String, gates: EnginePlatformGates = .current) async -> TranscriptionEngine {
        let engine: TranscriptionEngine

        if selectedEngine == "fluidaudio" {
            engine = await FluidAudioEngine()
        } else if selectedEngine == "sensevoice" {
#if os(macOS) && arch(arm64)
            engine = gates.supportsSenseVoice ? SenseVoiceEngine() : await WhisperEngine()
#else
            // SenseVoice (sherpa-onnx/onnxruntime) ships macOS-arm64-only; every other
            // platform (Intel mac, iOS) falls back to Whisper.
            engine = await WhisperEngine()
#endif
        } else if selectedEngine == "remote" {
            engine = RemoteEngine()
        } else if selectedEngine == "apple" {
#if os(macOS) && canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                // The #available wrapper is load-bearing: the compiler requires it as
                // availability proof for the AppleSpeechEngine type. The gates parameter
                // decides WITHIN a host that can construct the engine.
                engine = gates.supportsAppleSpeech ? AppleSpeechEngine() : await WhisperEngine()
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

        return engine
    }

    /// Pure engine-kind mapping for a specific model option (the remote local-fallback
    /// path): option in, un-initialized engine out. Same construction-only contract as
    /// `makeEngine(selectedEngine:)`. Pure → `nonisolated` + testable.
    nonisolated static func makeEngine(modelOption option: DictationModelOption, gates: EnginePlatformGates = .current) async -> TranscriptionEngine {
        let engine: TranscriptionEngine
        switch option.engine {
        case "fluidaudio":
            engine = await FluidAudioEngine(versionOverride: option.identifier)
        case "apple":
#if os(macOS) && canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                engine = gates.supportsAppleSpeech ? AppleSpeechEngine() : await WhisperEngine()
            } else {
                engine = await WhisperEngine()
            }
#else
            engine = await WhisperEngine()
#endif
        case "sensevoice":
#if os(macOS) && arch(arm64)
            engine = gates.supportsSenseVoice ? SenseVoiceEngine() : await WhisperEngine(modelPathOverride: option.identifier)
#else
            engine = await WhisperEngine(modelPathOverride: option.identifier)
#endif
        default: // "whisper"
            engine = await WhisperEngine(modelPathOverride: option.identifier)
        }
        return engine
    }

    /// Build + initialize an engine for a specific model (only for the remote
    /// local-fallback), without touching the global engine/model prefs. Runs the load
    /// off the main actor, like `ensureEngineLoaded`.
    private func makeEngine(for option: DictationModelOption) async throws -> TranscriptionEngine {
        try await Task.detached(priority: .userInitiated) { () -> TranscriptionEngine in
            let engine = await Self.makeEngine(modelOption: option)
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

public enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}

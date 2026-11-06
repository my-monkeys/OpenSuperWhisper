import AVFoundation
import Foundation

@MainActor
public class TranscriptionService: ObservableObject {
    public static let shared = TranscriptionService()

    /// One-permit gate serializing every transcription across the whole app. See the note in
    /// `transcribeAudio` — the engines share one non-thread-safe context. (parallel-recording #2)
    private static let engineGate = AsyncSemaphore(1)

    @Published public private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published public private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    @Published public private(set) var engineError: String?

    var isEngineReady: Bool {
        currentEngine != nil && !isLoading
    }

    private var currentEngine: TranscriptionEngine?
    private var loadedEngineKind: String?
    private var engineGeneration = 0
    private var totalDuration: Float = 0.0
    private let engineBuilder: (EngineKind) async -> TranscriptionEngine

    /// The model that actually produced the most recent transcription, and whether it
    /// came from the remote local-fallback. Read by the recording-save paths so history
    /// shows the real model (and flags fallbacks). Set on the main actor per run.
    public private(set) var lastUsedModel: DictationModelOption?
    public private(set) var lastUsedFallback = false
    /// How the most recent run spent its time inside the engine gate (#262). Read right after
    /// `transcribeAudio` returns, for the same reason as `lastUsedModel`: it is per-run state,
    /// and the caller's snapshot has to be taken before any `await` can let another
    /// transcription overwrite it.
    ///
    /// It is overwritten per run, so on a retried dictation it describes the successful attempt
    /// while the caller's elapsed time covers both. Per-attempt splits are a non-goal.
    public private(set) var lastRunTimings: RunTimings?

    /// What one run inside `transcribeAudio` cost, in integer milliseconds. `engineLoadMs` is
    /// nil when the engine never loaded (a thrown load), which is different from 0.
    public struct RunTimings: Equatable, Sendable {
        public let engineWaitMs: Int?
        public let engineLoadMs: Int?

        public init(engineWaitMs: Int?, engineLoadMs: Int?) {
            self.engineWaitMs = engineWaitMs
            self.engineLoadMs = engineLoadMs
        }
    }

    /// Test seam: the clock the run timings are measured with. Production uses the house
    /// monotonic clock.
    var uptime: () -> UInt64 = UptimeClock.now
    private var lastEngineLoadMs: Int?
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    
    init(engineBuilder: @escaping (EngineKind) async -> TranscriptionEngine = TranscriptionService.buildEngine) {
        self.engineBuilder = engineBuilder
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
    /// active, and return it. Called lazily from transcribeAudio, so selecting an
    /// engine in Settings only records the choice — the model isn't downloaded/loaded
    /// until you actually transcribe with it. Heavy work runs off the main actor.
    /// When `reloadEngine` runs during the load, the engine still goes to this caller,
    /// whose model it is, but isn't kept: the next caller loads the current choice.
    private func ensureEngineLoaded() async -> TranscriptionEngine? {
        let selectedEngine = CoreAccess.preferences.selectedEngine
        if let currentEngine, loadedEngineKind == selectedEngine { return currentEngine }

        isLoading = true
        engineError = nil
        print("Loading engine: \(selectedEngine)")

        let generation = engineGeneration
        let kind = Self.engineKind(forSelectedEngine: selectedEngine)
        let result = await Task.detached(priority: .userInitiated) { [engineBuilder] () -> Result<TranscriptionEngine?, Error> in
            let engine: TranscriptionEngine? = await engineBuilder(kind)

            do {
                try await engine?.initialize()
                return .success(engine)
            } catch {
                return .failure(error)
            }
        }.value

        guard generation == engineGeneration else {
            isLoading = false
            return try? result.get()
        }

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
        return currentEngine
    }

    /// The engines `ensureEngineLoaded` can build. Named apart from the classes so the choice can
    /// be made, and tested, without instantiating anything (an engine's init may load a model).
    /// `CaseIterable` so `EngineCapabilities.allEngineIds` can be pinned against every kind:
    /// a new kind whose id never reaches the list is otherwise invisible to the capability test.
    enum EngineKind: Equatable, CaseIterable {
        case whisper, fluidAudio, senseVoice, remote, appleSpeech
    }

    /// Which engine a stored `selectedEngine` id gets. Every id the app does not know lands on
    /// Whisper rather than failing, including an empty one and the legacy "groq", which
    /// AppPreferences rewrites to "remote" when it is first built, so it only gets here when it
    /// was written after that.
    ///
    /// The two gates are parameters so the fallbacks can be tested on any machine; the defaults
    /// are the checks the app makes.
    nonisolated static func engineKind(
        forSelectedEngine id: String,
        senseVoiceAvailable: Bool = isSenseVoiceCompiled,
        appleSpeechAvailable: Bool = isAppleSpeechAvailable
    ) -> EngineKind {
        switch id {
        case "fluidaudio":
            return .fluidAudio
        case "sensevoice":
            // SenseVoice (sherpa-onnx/onnxruntime) ships arm64-only; fall back on Intel.
            return senseVoiceAvailable ? .senseVoice : .whisper
        case "remote":
            return .remote
        case "apple":
            // A pref synced from a newer machine; the catalog never offers "apple" there, so
            // quietly fall back.
            return appleSpeechAvailable ? .appleSpeech : .whisper
        default:
            return .whisper
        }
    }

    /// The engine `ensureEngineLoaded` builds for `kind`, not yet initialized. No init here
    /// loads anything (they only store their arguments), so tests can check the class.
    nonisolated static func buildEngine(_ kind: EngineKind) async -> TranscriptionEngine {
        switch kind {
        case .fluidAudio:
            return await FluidAudioEngine()
        case .senseVoice:
#if os(macOS) && arch(arm64)
            return SenseVoiceEngine()
#else
            // Unreachable: engineKind never answers .senseVoice where it isn't compiled.
            return await WhisperEngine()
#endif
        case .remote:
            return RemoteEngine()
        case .appleSpeech:
#if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) {
                return AppleSpeechEngine()
            } else {
                // Unreachable: engineKind never answers .appleSpeech below macOS 26.
                return await WhisperEngine()
            }
#else
            // Unreachable: engineKind never answers .appleSpeech without FoundationModels.
            return await WhisperEngine()
#endif
        case .whisper:
            return await WhisperEngine()
        }
    }

    nonisolated static var isSenseVoiceCompiled: Bool {
#if os(macOS) && arch(arm64)
        return true
#else
        return false
#endif
    }

    nonisolated static var isAppleSpeechAvailable: Bool {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return true }
#endif
        return false
    }

    /// Invalidate the active engine so the next transcription re-initializes it
    /// (used when the engine selection or model changes). Intentionally does NOT
    /// load or download anything — that's deferred to next use. Clears any stale
    /// load error, since the invalidated engine gets a fresh attempt next time.
    /// An engine still loading is invalidated too: it serves only the caller waiting on it.
    public func reloadEngine() {
        engineGeneration += 1
        currentEngine = nil
        loadedEngineKind = nil
        engineError = nil
    }
    
    public func reloadModel(with path: String) {
        if CoreAccess.preferences.selectedEngine == "whisper" {
            CoreAccess.preferences.selectedWhisperModelPath = path
            reloadEngine()
        }
    }

    /// Temporarily switch to `option` for one transcription and return a closure that restores the
    /// previous engine/model. No-op (returns an empty closure) when `option` is nil or already the
    /// active model. Called from inside `transcribeAudio`'s serialization gate so the swap can't
    /// leak to a concurrent caller — every one-off model (dictation clip AND the rerun dropdown,
    /// which now passes its option through `transcribeAudio(modelOverride:)`) runs through here.
    private func applyOneOffModel(_ option: DictationModelOption?) -> () -> Void {
        guard let option else { return {} }
        let current = ModelCatalog.activeOption()
        if current?.engine == option.engine && current?.identifier == option.identifier { return {} }

        let prefs = CoreAccess.preferences
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
    
    /// - Parameter capturedFieldText: what was already written in the field the dictation started
    ///   in, captured at record-start by the host and carried per clip. It is resolved into a
    ///   `FieldContext` only after the engine is known, and reaches an engine only through a
    ///   context protocol — see `resolveFieldContext`. Chosen over a member on
    ///   `TranscriptionSettings` because that value is handed to every engine, including the
    ///   remote one (#89).
    public func transcribeAudio(url: URL, settings: TranscriptionSettings,
                                capturedFieldText: String? = nil,
                                modelOverride: DictationModelOption? = nil) async throws -> String {
        // Resolve the field's context before taking the gate when the engine that will run is
        // already loaded. The spelling pass is synchronous main-thread work, and holding the
        // process-wide permit through it delays whatever dictation is queued behind this one.
        //
        // Only when no per-call model swap can change the engine, and an engine of the selected
        // kind is already loaded — the two conditions under which `ensureEngineLoaded` below
        // returns this same instance. Every other path resolves after selection, as it did.
        let readyContext: FieldContext? = modelOverride == nil
            && loadedEngineKind == CoreAccess.preferences.selectedEngine
            ? currentEngine.flatMap {
                resolveFieldContext(capturedFieldText, for: $0, settings: settings)
            }
            : nil

        // Serialize every transcription across the app (dictation pipeline, file-drop queue,
        // reruns, CLI): the engines share one non-thread-safe context (e.g. whisper.cpp) and this
        // object's per-run state (isTranscribing/progress/lastUsedModel). Two overlapping calls
        // would crash or corrupt output. (parallel-recording #2)
        let gateStart = uptime()
        await Self.engineGate.wait()
        let engineWaitMs = UptimeClock.milliseconds(from: gateStart, to: uptime())
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

        // Published on both the returning and the throwing path: a run that failed after
        // spending 15 s waiting for a model is exactly what the measurement is for.
        lastEngineLoadMs = nil
        defer {
            lastRunTimings = RunTimings(engineWaitMs: engineWaitMs,
                                        engineLoadMs: lastEngineLoadMs)
        }
        return try await transcribe(url: url, settings: settings, fallbackModel: nil,
                                    capturedFieldText: capturedFieldText,
                                    preResolvedContext: readyContext)
    }

    /// Load the appropriate engine and transcribe. On a fallback-worthy remote error
    /// (server unreachable / 5xx after retries), re-runs once with the configured local
    /// fallback model. Recursive by design: the `fallbackModel != nil` attempt is
    /// guarded out of the catch (`fallbackModel == nil`), so it can never loop.
    private func transcribe(url: URL, settings: TranscriptionSettings,
                            fallbackModel: DictationModelOption?,
                            capturedFieldText: String?,
                            preResolvedContext: FieldContext?) async throws -> String {
        let engine: TranscriptionEngine
        if let fallbackModel {
            // The fallback engine is built AND initialized here, so a user on remote-with-
            // fallback pays this cold load; leaving it nil hid it from the report.
            let fallbackLoadStart = uptime()
            engine = try await makeEngine(for: fallbackModel)
            lastEngineLoadMs = UptimeClock.milliseconds(from: fallbackLoadStart, to: uptime())
            lastUsedModel = fallbackModel
            lastUsedFallback = true
        } else {
            // Lazily initialize the selected engine on first use (downloads a local
            // model only now, never on mere engine selection in Settings).
            let activeOption = ModelCatalog.activeOption()
            let loadStart = uptime()
            guard let loaded = await ensureEngineLoaded() else {
                throw TranscriptionError.contextInitializationFailed
            }
            // 0 when the engine was already up; left nil when the load never completed.
            lastEngineLoadMs = UptimeClock.milliseconds(from: loadStart, to: uptime())
            engine = loaded
            lastUsedModel = activeOption
            lastUsedFallback = false
        }

        // Resolved here, after the engine is known: an engine receives context only if it
        // declared a context protocol, and the preference gate is evaluated at dispatch time so
        // a setting switched off between recording and transcription behaves as it did before.
        //
        // A value resolved before the gate is reused only if it fits the engine that actually
        // ran. If a reload or an engine switch replaced that engine in the meantime, the value
        // is discarded here and resolved again — never passed to an engine it does not match.
        let context = preResolvedContext.flatMap { $0.matches(engine) ? $0 : nil }
            ?? resolveFieldContext(capturedFieldText, for: engine, settings: settings)
        do {
            return try await runOnEngine(engine, url: url, settings: settings, context: context)
        } catch let error where fallbackModel == nil && Self.shouldUseFallback(for: error) {
            guard CoreAccess.preferences.remoteFallbackEnabled,
                  CoreAccess.preferences.selectedEngine == "remote",
                  let fallback = CoreAccess.preferences.remoteFallbackModel else {
                throw error
            }
            print("Remote transcription failed (\(error)); falling back to local model \(fallback.displayName)")
            // The fallback re-resolves against its own engine. It is safe to pass the text on:
            // the record-time gate refused to capture it under the remote engine, so a
            // remote-then-local clip has nothing to pass.
            // No pre-resolved value: the fallback engine is a different one, and resolves its
            // own context from the same clip text.
            return try await transcribe(url: url, settings: settings, fallbackModel: fallback,
                                        capturedFieldText: capturedFieldText,
                                        preResolvedContext: nil)
        }
    }

    /// The language the spelling dictionary should judge the field's words in, or nil for "the
    /// user's own languages".
    ///
    /// The clip's language, not the app's preference: a dictation transcribed in French must not
    /// have its field checked against whichever language happened to be selected earlier.
    ///
    /// "auto" maps to nil, because it is not a language a dictionary can look a word up in — the
    /// engine detects it from audio that had not been spoken when this text was written. Nil asks
    /// the dictionary for the user's preferred languages, which is what the old preference-read
    /// path did whenever the preference was "auto", and is the only honest answer available.
    ///
    /// The keyboard-layout selection code never reaches here: `DictationPipeline.process`
    /// resolves it into a concrete language before these settings are built.
    nonisolated static func spellingLanguage(for selectedLanguage: String) -> String? {
        selectedLanguage == "auto" ? nil : selectedLanguage
    }

    /// What this engine is allowed to see of the field, or nil when it is allowed nothing.
    ///
    /// The two gates are deliberate: the preference (the user asked) and the conformance (this
    /// engine has somewhere to put it). Neither alone is a reason to hand over someone's
    /// document. A non-conforming engine reaches the `nil` return and is then called with the
    /// plain `transcribeAudio(url:settings:)` — the argument is never passed, which is the
    /// defensive strip in its only honest form.
    private func resolveFieldContext(_ text: String?, for engine: TranscriptionEngine,
                                     settings: TranscriptionSettings) -> FieldContext? {
        guard let text = TranscriptionPrompt.surroundingText(
            enabled: settings.useSurroundingTextAsContext, captured: text) else { return nil }

        // The mode, not only the conformance. The capture gate already refused to read the field
        // for an engine that cannot use it, but that is one layer, and the layer that is easy to
        // bypass — a test stub, a future engine, a fallback path. Checking the selected id here
        // means a conforming engine selected as `remote` still receives nothing, so the refusal
        // holds even when the gate did not run.
        guard EngineCapabilities.supportsFieldContext(engine: CoreAccess.preferences.selectedEngine)
        else { return nil }

        if engine is ProseContextEngine { return .prose(text) }
        // The spelling pass runs only here: a prose engine returned above, and an engine with
        // nowhere to put a term list returns below without one.
        guard engine is TermContextEngine else { return nil }
        let terms = FieldContextTerms.terms(
            from: text,
            spelling: CoreAccess.fieldTermSpelling(
                Self.spellingLanguage(for: settings.selectedLanguage)),
            capitalMarksNames: LanguageUtil.marksNamesWithCapitals(settings.selectedLanguage))
        return terms.isEmpty ? nil : .terms(terms)
    }

    /// Dispatch one transcription, passing the field context only to an engine that declared it
    /// can use it. `nonisolated` because it runs where the transcription runs, off the main actor.
    ///
    /// The final branch is the defensive strip in its only honest form: on every path that does
    /// not match a conforming engine the context argument is simply not passed, so a mistaken
    /// capability flip drops the context rather than sending it.
    private nonisolated static func transcribe(_ engine: TranscriptionEngine, url: URL,
                                               settings: TranscriptionSettings,
                                               context: FieldContext?) async throws -> String {
        if case .prose(let text)? = context, let proseEngine = engine as? ProseContextEngine {
            return try await proseEngine.transcribeAudio(url: url, settings: settings, proseContext: text)
        }
        if case .terms(let terms)? = context, let termEngine = engine as? TermContextEngine {
            return try await termEngine.transcribeAudio(url: url, settings: settings, terms: terms)
        }
        return try await engine.transcribeAudio(url: url, settings: settings)
    }

    /// Run one transcription on a specific engine: wire its progress callback, run it
    /// off the main actor, and honor cancellation. Any engine error propagates so the
    /// caller (`transcribe`) can decide whether to fall back.
    private func runOnEngine(_ engine: TranscriptionEngine, url: URL,
                             settings: TranscriptionSettings,
                             context: FieldContext?) async throws -> String {
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

            let result = try await Self.transcribe(engine, url: url, settings: settings, context: context)

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
        let choice = Self.fallbackEngineChoice(for: option)
        // Test seam: the real fallback engine needs a model file, so a test injects a stub to
        // exercise the fallback path at all. Production keeps the real builder.
        let build = fallbackEngineBuilder
        return try await Task.detached(priority: .userInitiated) { () -> TranscriptionEngine in
            let engine = await build(choice)
            try await engine.initialize()
            return engine
        }.value
    }

    /// Test seam: builds the engine the remote local-fallback runs on. Production builds the real
    /// engine for the choice with `buildFallbackEngine`.
    var fallbackEngineBuilder: (FallbackEngineChoice) async -> TranscriptionEngine = TranscriptionService.buildFallbackEngine

    /// The engines the remote local-fallback can build, with what each is given. Separate from
    /// `EngineKind` because this factory has its own quirks, kept as they are (see below).
    enum FallbackEngineChoice: Equatable {
        case fluidAudio(version: String)
        case appleSpeech
        case senseVoice
        case whisper(modelPathOverride: String?)
    }

    /// Which engine `makeEngine(for:)` builds for the configured fallback model. The gates are
    /// parameters, like `engineKind`'s, so both sides can be tested on any machine.
    ///
    /// Three answers look wrong and are pinned as they are. "apple" without Apple Speech gets
    /// Whisper with no override, so the user's selected Whisper model rather than the fallback.
    /// "sensevoice" without SenseVoice passes the option's identifier, which is "default", as a
    /// Whisper model path, which cannot load. Any other engine, "remote" included, also passes
    /// its identifier as a Whisper model path.
    nonisolated static func fallbackEngineChoice(
        for option: DictationModelOption,
        senseVoiceAvailable: Bool = isSenseVoiceCompiled,
        appleSpeechAvailable: Bool = isAppleSpeechAvailable
    ) -> FallbackEngineChoice {
        switch option.engine {
        case "fluidaudio":
            return .fluidAudio(version: option.identifier)
        case "apple":
            return appleSpeechAvailable ? .appleSpeech : .whisper(modelPathOverride: nil)
        case "sensevoice":
            // SenseVoice has a single model, so the identifier is ignored where it is compiled.
            return senseVoiceAvailable ? .senseVoice : .whisper(modelPathOverride: option.identifier)
        default: // "whisper"
            return .whisper(modelPathOverride: option.identifier)
        }
    }

    /// The engine `makeEngine(for:)` builds for `choice`, not yet initialized.
    nonisolated static func buildFallbackEngine(_ choice: FallbackEngineChoice) async -> TranscriptionEngine {
        switch choice {
        case .fluidAudio(let version):
            return await FluidAudioEngine(versionOverride: version)
        case .appleSpeech:
#if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) {
                return AppleSpeechEngine()
            } else {
                // Unreachable: fallbackEngineChoice never answers .appleSpeech below macOS 26.
                return await WhisperEngine()
            }
#else
            // Unreachable: fallbackEngineChoice never answers .appleSpeech without FoundationModels.
            return await WhisperEngine()
#endif
        case .senseVoice:
#if os(macOS) && arch(arm64)
            return SenseVoiceEngine()
#else
            // Unreachable: fallbackEngineChoice never answers .senseVoice where it isn't compiled.
            return await WhisperEngine()
#endif
        case .whisper(let modelPathOverride):
            return await WhisperEngine(modelPathOverride: modelPathOverride)
        }
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

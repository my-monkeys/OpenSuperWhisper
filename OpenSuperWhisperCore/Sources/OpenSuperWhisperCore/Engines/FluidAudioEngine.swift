import Foundation
import AVFoundation
import FluidAudio

class FluidAudioEngine: TranscriptionEngine, TermContextEngine {
    var engineName: String { "FluidAudio" }

    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    /// The CTC models the vocabulary path spots with, loaded the first time a boost is actually
    /// used: ~64 MB a user with no dictionary boost, no snippet boost and no field context never
    /// pays for.
    ///
    /// No cache key: the CTC model is chosen by `CtcModelVariant`, not by the ASR model version.
    /// The file path this replaced always asked for `.ctc110m` whatever `AsrModelVersion` ran,
    /// so one load serves every dictation this engine transcribes.
    private var ctcModels: CtcModels?
    private var isCancelled = false
    private var transcriptionTask: Task<String, Error>?
    private var progressTask: Task<Void, Never>?

    /// When set ("v2", "v3" or "ultra"), overrides the pref-selected model version — lets the
    /// remote local-fallback build an engine for a specific model without mutating
    /// global prefs. Readable so a test can check what the fallback factory passed.
    let versionOverride: String?

    /// A belt for hosts that build an engine without the app's startup entry. `AppCore.install`
    /// calls `FluidAudioLogging.keepDictationTextOutOfTheLog()` at launch, before the live preview
    /// can log; this covers a host that installs a configuration and builds an engine directly.
    private static let logLevelConfigured: Void = {
        FluidAudioLogging.keepDictationTextOutOfTheLog()
    }()

    init(versionOverride: String? = nil) {
        _ = Self.logLevelConfigured
        self.versionOverride = versionOverride
    }
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        asrManager != nil
    }
    
    func initialize() async throws {
        let versionString = versionOverride ?? CoreAccess.preferences.fluidAudioModelVersion
        let version = AsrModelVersion(preference: versionString)

        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        asrManager = manager
        asrModels = models
    }
    
    func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
        try await transcribe(url: url, settings: settings, fieldTerms: [])
    }

    /// The same, biased toward terms reduced from the focused field (#89). The terms arrive
    /// already gated by the preference and resolved by `TranscriptionService`, and are merged
    /// with the dictionary and snippet lists here — one place, so the three can never drift.
    func transcribeAudio(url: URL, settings: TranscriptionSettings,
                         terms: [String]) async throws -> String {
        try await transcribe(url: url, settings: settings, fieldTerms: terms)
    }

    private func transcribe(url: URL, settings: TranscriptionSettings,
                            fieldTerms: [String]) async throws -> String {
        guard let asrManager = asrManager else {
            throw TranscriptionError.contextInitializationFailed
        }

        isCancelled = false
        
        // Notify start
        onProgressUpdate?(0.02)
        
        guard !isCancelled else {
            throw CancellationError()
        }
        
        // Start progress monitoring task using FluidAudio's transcriptionProgressStream
        let onProgress = onProgressUpdate
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                // Get the real progress stream from FluidAudio
                let progressStream = await asrManager.transcriptionProgressStream
                
                for try await progress in progressStream {
                    guard !Task.isCancelled, !self.isCancelled else { break }
                    
                    // FluidAudio reports 0.0-1.0, we map to 0.05-0.95
                    let scaledProgress = 0.05 + Float(progress) * 0.90
                    
                    await MainActor.run {
                        onProgress?(scaledProgress)
                    }
                }
            } catch {
                // Stream finished or error
            }
        }
        
        defer {
            progressTask?.cancel()
            progressTask = nil
        }

        // Always the offline AsrManager, the more accurate decoder for a whole file. Terms to
        // boost are applied afterwards by rescoring its result against the audio, as
        // FluidAudio's own batch transcription does (#235). They used to send the file through
        // the sliding-window decoder instead, which reloaded every model on each dictation.
        let plan = boostPlan(settings, fieldTerms: fieldTerms)
        let samples = try await Self.samplesIfNeeded(url: url, forBoosting: !plan.terms.isEmpty)
        // A fresh TDT decoder state per file keeps transcriptions independent.
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = if let samples {
            try await asrManager.transcribe(samples, decoderState: &decoderState)
        } else {
            try await asrManager.transcribe(url, decoderState: &decoderState)
        }
        var rawText = result.text
        if !plan.terms.isEmpty, let samples, let timings = result.tokenTimings,
           let rescored = await rescore(rawText, timings: timings, samples: samples, plan: plan) {
            rawText = rescored
        }

        guard !isCancelled else {
            throw CancellationError()
        }

        // Finalize
        onProgressUpdate?(0.95)

        let processedText = TranscriptionPostProcessing.finish(rawText, settings: settings)

        onProgressUpdate?(1.0)

        return processedText
    }
    
    func cancelTranscription() {
        isCancelled = true
        progressTask?.cancel()
        progressTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    
    func getSupportedLanguages() -> [String] {
        EngineCapabilities.supportedLanguages(
            engine: "fluidaudio", fluidAudioModelVersion: CoreAccess.preferences.fluidAudioModelVersion)
    }

    /// The terms to boost toward and where they came from: the dictionary and the clip's snippet
    /// triggers, then as much of the field as the cap allows.
    ///
    /// The dictionary and snippet parts are the same `RecognitionBoost` merge Whisper's prompt
    /// boost (`TranscriptionSettings.recognitionBoostTerms`) and the live streaming preview
    /// (`IndicatorWindow`) build. Field terms are Parakeet's alone: Whisper gets the field as
    /// surrounding prose, and the preview does not receive field terms at all. Keeping the live
    /// preview out of this change is deliberate.
    ///
    /// Boosting is opt-in for all three (separate from the always-on replacement): only bias the
    /// decoder when the user explicitly enabled it (#over-boost).
    ///
    /// The cap applies to the field's contribution only. The other two lists had no cap before
    /// this feature and dictionaries have no entry limit, so capping the merged list would
    /// truncate an existing user's boost — a regression for someone who changed nothing. The
    /// field keeps at least `minimumFieldSlots` even when the base list already exceeds the cap,
    /// so a 50+ term dictionary cannot make the toggle a no-op (#126).
    func boostPlan(_ settings: TranscriptionSettings,
                   fieldTerms: [String]) -> RecognitionBoost.Plan {
        let dictionary = CoreAccess.preferences.dictionaryBoostTerms
        let base = RecognitionBoost.terms(dictionary: dictionary, snippets: settings.snippetTriggers)
        let allowance = min(fieldTerms.count,
                            max(Self.minimumFieldSlots, Self.mergedTermLimit - base.count))
        return RecognitionBoost.plan(dictionary: dictionary,
                                     snippets: settings.snippetTriggers,
                                     field: Array(fieldTerms.prefix(allowance)))
    }

    /// The merged list alone. Internal rather than private so a core test can pin the cross-clip
    /// rule directly: clip B must never be boosted with clip A's field terms, and the merged list
    /// is where that is visible without running a model.
    func activeBoostTerms(_ settings: TranscriptionSettings,
                          fieldTerms: [String]) -> [String] {
        boostPlan(settings, fieldTerms: fieldTerms).terms
    }

    /// FluidAudio's own bands: 1–50 excellent, 50–100 good, 100–230 tested. Only the field's
    /// share is held to it.
    static let mergedTermLimit = 50

    /// Field context keeps at least this many terms even past `mergedTermLimit`; dropping to
    /// `max(0, 50 - base)` made the toggle inert for a 50+ term dictionary (#126).
    static let minimumFieldSlots = 5

    /// The similarity a field term must reach before the rescorer may replace a transcript word
    /// with it. Above every band floor (0.52/0.55/0.60), so field context is not a licence to
    /// rewrite a common word: the measured "prey" → "Priya" flip is 0.600 (#307).
    static let fieldTermMinSimilarity: Float = 0.75

    /// The rescorer's settings for dictation. The short-term taper scales the added boost down by
    /// token count — a reduction, not a guard: a scaled boost can still flip the comparison, and
    /// it knows nothing about vocabulary-ness. The sourced figure is the spotter rescue: off, it
    /// took false positives from ~94 to ~19 on a 90-clip set (`ContextBiasingConstants.swift`).
    static let rescorerConfig = VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false)

    /// A term as the boosting session receives it, with the similarity floor it carries.
    struct BoostVocabularyTerm {
        let text: String
        let ctcTokenIds: [Int]
        let minSimilarity: Float
    }

    /// The session's terms, tokenised here so it does not parse `tokenizer.json` itself:
    /// `VocabularyBoostingSession.init` only loads `CtcTokenizer` when some term lacks CTC token
    /// ids, while the `VocabularyRescorer.create` it calls always loads one. After the tokenizer
    /// below is warm a rebuild therefore costs one parse of the tokenizer file plus one BPE
    /// encode per term; the first boost of a process also pays the tokenizer's own load.
    /// (Verified against FluidAudio 0.18.3, the pin in Package.resolved.)
    ///
    /// A term the tokenizer cannot encode is dropped, exactly as
    /// `CustomVocabularyContext.tokenizingMissingCtcTokens` drops it. Every surviving term carries
    /// an explicit floor, because the session's fallback
    /// `max(thresholds.minSimilarity ?? sizeConfig.minSimilarity, vocabulary.minSimilarity)`
    /// (`VocabularyBoostingSession.minSimilarity`) is still moved by the field's terms for a
    /// dictionary that did not change. Base terms keep the floor their own list size gives them;
    /// the count is taken after the drop, the same grain `VocabularyBoostingSession.init` uses for
    /// its `ContextBiasingConstants.rescorerConfig(forVocabSize:)` band.
    static func vocabularyTerms(for plan: RecognitionBoost.Plan,
                                encode: (String) -> [Int]) -> [BoostVocabularyTerm] {
        let encoded = plan.terms.compactMap { text -> (text: String, ctcTokenIds: [Int])? in
            guard !text.isEmpty else { return nil }
            let ids = encode(text)
            return ids.isEmpty ? nil : (text: text, ctcTokenIds: ids)
        }
        let baseCount = encoded.reduce(0) {
            $0 + (plan.fieldForms.contains($1.text.lowercased()) ? 0 : 1)
        }
        let baseFloor = max(
            ContextBiasingConstants.rescorerConfig(forVocabSize: baseCount).minSimilarity,
            ContextBiasingConstants.defaultMinSimilarity)
        return encoded.map { term in
            BoostVocabularyTerm(
                text: term.text,
                ctcTokenIds: term.ctcTokenIds,
                minSimilarity: plan.fieldForms.contains(term.text.lowercased())
                    ? Self.fieldTermMinSimilarity : baseFloor)
        }
    }

    /// The one-slot cache of boosting sessions: the terms are tokenised once, then one session
    /// serves every dictation until the dictionary, the snippets or the field's terms change.
    ///
    /// The key is the whole plan, not the merged texts: a dictionary "Priya" and a field "Priya"
    /// merge to the same list but carry different floors, so a texts-only key would serve either
    /// floor for the other. Internal and generic so a test can drive it without CTC models;
    /// `builds` counts every stored miss, which is what makes a silent rebuild (or a silent hit)
    /// visible.
    struct BoostSessionCache<Session> {
        private var plan: RecognitionBoost.Plan?
        private var session: Session?
        private(set) var builds = 0

        // Explicit because the stored properties are private: the synthesized memberwise
        // initializer would be private and the test could not build an empty cache.
        init() {}

        func cached(for plan: RecognitionBoost.Plan) -> Session? {
            // A complete key: the floors are a pure function of the plan and the engine's one
            // cached tokenizer, so no floor can depend on anything outside it.
            self.plan == plan ? session : nil
        }

        mutating func store(_ session: Session, for plan: RecognitionBoost.Plan) {
            self.plan = plan
            self.session = session
            builds += 1
        }
    }

    private var boostSessions = BoostSessionCache<VocabularyBoostingSession>()

    /// The transcript rescored toward the boost terms, or nil to keep it. Never throws: boosting
    /// failing is logged and the plain transcript is used.
    private func rescore(_ text: String, timings: [TokenTiming], samples: [Float],
                         plan: RecognitionBoost.Plan) async -> String? {
        do {
            let session = try await boostingSession(for: plan)
            return await session.rescore(text: text, tokenTimings: timings, audioSamples: samples)?.text
        } catch {
            print("Parakeet vocabulary boosting unavailable, keeping the plain transcript: \(error)")
            return nil
        }
    }

    private func boostingSession(for plan: RecognitionBoost.Plan) async throws -> VocabularyBoostingSession {
        if let cached = boostSessions.cached(for: plan) { return cached }
        // Built in code. The path this replaced joined the terms with newlines into a temporary
        // file, where a term containing ":", a leading "#", a newline or "{" would have been
        // read as the loader's own syntax. Terms reduced from a field of prose are the first
        // that can contain any of those.
        let vocabulary = CustomVocabularyContext(terms: try await vocabulary(for: plan))
        let session = try await VocabularyBoostingSession(vocabulary: vocabulary,
                                                          ctcModels: try await vocabularyModels(),
                                                          config: Self.rescorerConfig)
        boostSessions.store(session, for: plan)
        return session
    }

    /// The terms the session receives for `plan`: the tokenized list with its floors.
    private func vocabulary(for plan: RecognitionBoost.Plan) async throws -> [CustomVocabularyTerm] {
        let models = try await vocabularyModels()
        let tokenizer = try await vocabularyTokenizer(for: models)
        return Self.vocabularyTerms(for: plan, encode: tokenizer.encode).map {
            CustomVocabularyTerm(text: $0.text, ctcTokenIds: $0.ctcTokenIds,
                                 minSimilarity: $0.minSimilarity)
        }
    }

    /// How many terms a session would actually receive for `plan`. Internal for the benchmark: a
    /// term the CTC tokenizer cannot encode is dropped, so an arm's input list cannot prove its
    /// boost was real — the inert arm exists to make that visible.
    func boostedTermCount(for plan: RecognitionBoost.Plan) async throws -> Int {
        guard !plan.terms.isEmpty else { return 0 }
        return try await vocabulary(for: plan).count
    }

    /// The CTC tokenizer, loaded once and reused: pre-tokenising every term is what lets the
    /// session skip its own load. The session and its rescorer are rebuilt per term list; the
    /// tokenizer file is the same one for every list.
    private var ctcTokenizer: CtcTokenizer?

    /// The folder holding the tokenizer.json that matches the CTC models: the folder they were
    /// loaded from, or the default cache when they carry none. The same rule the session applies
    /// for its own load (`CtcModels.tokenizerDirectory(loadedFrom:variant:)`, internal at the pin,
    /// so it is re-expressed here with public API).
    static func tokenizerDirectory(modelsDirectory: URL?, defaultDirectory: URL) -> URL {
        modelsDirectory ?? defaultDirectory
    }

    private func vocabularyTokenizer(for models: CtcModels) async throws -> CtcTokenizer {
        if let ctcTokenizer { return ctcTokenizer }
        let directory = Self.tokenizerDirectory(
            modelsDirectory: models.directory,
            defaultDirectory: CtcModels.defaultCacheDirectory(for: models.variant))
        let tokenizer = try await CtcTokenizer.load(from: directory)
        ctcTokenizer = tokenizer
        return tokenizer
    }

    /// The CTC models, loaded once and reused. The session is rebuilt whenever the term list
    /// changes; the models it runs on are the same for every list.
    private func vocabularyModels() async throws -> CtcModels {
        if let ctcModels { return ctcModels }
        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        ctcModels = models
        return models
    }

    /// Samples to hand FluidAudio in place of the file, or nil to let it read the file itself.
    /// A dictation always comes as samples, padded with silence (`ClipEdgePadding`). The recorder
    /// writes every input channel of an external device. FluidAudio downmixes such a file with
    /// AVAudioConverter, which turns speech carried by one of several unlabeled channels into
    /// silence, so a multi-channel file goes through the active-channel mix instead. A long mono
    /// file goes through it too when it is quiet enough to be lifted (`QuietClipGain`); any other
    /// keeps FluidAudio's reader, which streams long files from disk.
    ///
    /// Boosting always needs the samples: the rescorer reads the audio behind the transcript.
    private static func samplesIfNeeded(url: URL, forBoosting: Bool) async throws -> [Float]? {
        let file = try AVAudioFile(forReading: url)
        let isMultiChannel = file.processingFormat.channelCount > 1
        let isDictation = ClipEdgePadding.fits(
            durationSeconds: Double(file.length) / file.processingFormat.sampleRate)
        guard try forBoosting || isMultiChannel || isDictation
                || AudioPCMConverter.staysBelowNormalLevel(url) else { return nil }
        guard let samples = try await AudioPCMConverter.convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        return isDictation ? ClipEdgePadding.padded(samples) : samples
    }
}


extension AsrModelVersion {
    /// The model a stored `fluidAudioModelVersion` names. Anything unrecognised loads v3, the
    /// default, so a preference written by a newer build still finds a model rather than none.
    public init(preference: String) {
        switch preference {
        case "v2": self = .v2
        case "ultra": self = .ultra
        default: self = .v3
        }
    }
}

/// Keeps dictation text out of FluidAudio's own logs.
///
/// The dependency's debug lines carry the transcript and the applied replacement pair, and in
/// Release the pair still reaches the unified log. The live preview builds a FluidAudio manager at
/// record start, before any `FluidAudioEngine` exists, so the app calls this from its startup
/// entry (`AppCore.install`, which `AppMain.main` runs before the GUI or the CLI); the engine's
/// initializer calls it too, for a host that skips that entry.
public enum FluidAudioLogging {

    /// Holds FluidAudio at warnings for the life of the process. The count-only "applied N
    /// replacement(s)" info line is dropped with the debug lines; nothing reads it.
    public static func keepDictationTextOutOfTheLog() {
        AppLogger.minimumLevel = .warning
    }
}

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

    init(versionOverride: String? = nil) {
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
        let boostTerms = activeBoostTerms(settings, fieldTerms: fieldTerms)
        let samples = try await Self.samplesIfNeeded(url: url, forBoosting: !boostTerms.isEmpty)
        // A fresh TDT decoder state per file keeps transcriptions independent.
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = if let samples {
            try await asrManager.transcribe(samples, decoderState: &decoderState)
        } else {
            try await asrManager.transcribe(url, decoderState: &decoderState)
        }
        var rawText = result.text
        if !boostTerms.isEmpty, let samples, let timings = result.tokenTimings,
           let rescored = await rescore(rawText, timings: timings, samples: samples, terms: boostTerms) {
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

    /// The custom-dictionary terms, the clip's snippet triggers and the field's terms to bias
    /// recognition toward, or `[]` when none is on. Same list as Whisper's prompt boost and the
    /// live streaming preview (`RecognitionBoost`).
    ///
    /// Boosting is opt-in for all three (separate from the always-on replacement): only bias the
    /// decoder when the user explicitly enabled it (#over-boost).
    ///
    /// The cap applies to the field's contribution only. The other two lists had no cap before
    /// this feature and dictionaries have no entry limit, so capping the merged list would
    /// truncate an existing user's boost — a regression for someone who changed nothing.
    /// Internal rather than private so a core test can pin the cross-clip rule directly: clip B
    /// must never be boosted with clip A's field terms, and the merged list is where that is
    /// visible without running a model.
    func activeBoostTerms(_ settings: TranscriptionSettings,
                          fieldTerms: [String]) -> [String] {
        let dictionary = CoreAccess.preferences.dictionaryBoostTerms
        let base = RecognitionBoost.terms(dictionary: dictionary, snippets: settings.snippetTriggers)
        let allowance = max(0, Self.mergedTermLimit - base.count)
        return RecognitionBoost.terms(dictionary: dictionary,
                                      snippets: settings.snippetTriggers,
                                      field: Array(fieldTerms.prefix(allowance)))
    }

    /// FluidAudio's own bands: 1–50 excellent, 50–100 good, 100–230 tested. Only the field's
    /// share is held to it.
    static let mergedTermLimit = 50

    /// The rescorer's settings for dictation. The short-term taper scales the added boost down by
    /// token count — a reduction, not a guard: a scaled boost can still flip the comparison, and
    /// it knows nothing about vocabulary-ness. The sourced figure is the spotter rescue: off, it
    /// took false positives from ~94 to ~19 on a 90-clip set (`ContextBiasingConstants.swift`).
    static let rescorerConfig = VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false)

    /// The boosting session for the last term list: its terms are tokenised once, then it serves
    /// every dictation until the dictionary, the snippets or the field's terms change.
    private var boosting: (terms: [String], session: VocabularyBoostingSession)?

    /// The transcript rescored toward the boost terms, or nil to keep it. Never throws: boosting
    /// failing is logged and the plain transcript is used.
    private func rescore(_ text: String, timings: [TokenTiming], samples: [Float], terms: [String]) async -> String? {
        do {
            let session = try await boostingSession(for: terms)
            return await session.rescore(text: text, tokenTimings: timings, audioSamples: samples)?.text
        } catch {
            print("Parakeet vocabulary boosting unavailable, keeping the plain transcript: \(error)")
            return nil
        }
    }

    private func boostingSession(for terms: [String]) async throws -> VocabularyBoostingSession {
        let terms = terms.filter { !$0.isEmpty }
        if let boosting, boosting.terms == terms { return boosting.session }
        // Built in code. The path this replaced joined the terms with newlines into a temporary
        // file, where a term containing ":", a leading "#", a newline or "{" would have been
        // read as the loader's own syntax. Terms reduced from a field of prose are the first
        // that can contain any of those.
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        let session = try await VocabularyBoostingSession(vocabulary: vocabulary,
                                                          ctcModels: try await vocabularyModels(),
                                                          config: Self.rescorerConfig)
        boosting = (terms, session)
        return session
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
    /// The recorder writes every input channel of an external device. FluidAudio downmixes such
    /// a file with AVAudioConverter, which turns speech carried by one of several unlabeled
    /// channels into silence, so a multi-channel file goes through the active-channel mix
    /// instead. A mono file goes through it too when it is quiet enough to be lifted
    /// (`QuietClipGain`); any other keeps FluidAudio's reader, which streams long files from disk.
    ///
    /// Boosting always needs the samples: the rescorer reads the audio behind the transcript.
    private static func samplesIfNeeded(url: URL, forBoosting: Bool) async throws -> [Float]? {
        let isMultiChannel = try AVAudioFile(forReading: url).processingFormat.channelCount > 1
        guard try forBoosting || isMultiChannel || AudioPCMConverter.staysBelowNormalLevel(url) else { return nil }
        guard let samples = try await AudioPCMConverter.convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        return samples
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

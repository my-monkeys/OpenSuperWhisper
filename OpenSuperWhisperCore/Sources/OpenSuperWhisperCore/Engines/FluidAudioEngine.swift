import Foundation
import AVFoundation
import FluidAudio

class FluidAudioEngine: TranscriptionEngine {
    var engineName: String { "FluidAudio" }
    
    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
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
        let boostTerms = activeBoostTerms(settings)
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

    /// The custom-dictionary terms and the clip's snippet triggers to bias recognition toward,
    /// or `[]` when neither boost is on. Same list as Whisper's prompt boost and the live
    /// streaming preview (`RecognitionBoost`).
    ///
    /// Boosting is opt-in for both (separate from the always-on replacement): only bias the
    /// decoder when the user explicitly enabled it (#over-boost).
    private func activeBoostTerms(_ settings: TranscriptionSettings) -> [String] {
        RecognitionBoost.terms(dictionary: CoreAccess.preferences.dictionaryBoostTerms,
                               snippets: settings.snippetTriggers)
    }

    /// The rescorer's settings for dictation. FluidAudio's tests on short terms: the taper took
    /// false replacements of common words by unspoken short terms from 12 to 0, and turning the
    /// spotter rescue off cut false positives by about 80% while raising recall (#235).
    static let rescorerConfig = VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false)

    /// The boosting session for the last term list: its CTC models load and its terms are
    /// tokenised once, then it serves every dictation until the dictionary or the snippets change.
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
        let vocabularyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisper-ParakeetVocabulary-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try terms.joined(separator: "\n").write(to: vocabularyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vocabularyURL) }
        let loaded = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabularyURL.path)
        let session = try await VocabularyBoostingSession(vocabulary: loaded.vocab, ctcModels: loaded.models,
                                                          config: Self.rescorerConfig)
        boosting = (terms, session)
        return session
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

import Foundation
import AVFoundation
import FluidAudio
import OpenSuperWhisperCore

/// Drives live (streaming) transcription on the Parakeet/FluidAudio engine.
///
/// Owns a `SlidingWindowAsrManager` plus its own microphone tap (an `AVAudioEngine`), running in
/// parallel with the WAV recorder so playback/history stay intact. Mic buffers are fed to the
/// manager, which emits `volatileTranscript` (in-progress, may change) and `confirmedTranscript`
/// (locked-in); we publish their combination for the live caption. On stop, `finish()` returns
/// the complete text for normal post-processing + insertion.
@MainActor
final class StreamingTranscriptionController: ObservableObject {
    static let shared = StreamingTranscriptionController()

    /// Live caption: confirmed text followed by the dimmed volatile tail.
    @Published private(set) var confirmedText: String = ""
    @Published private(set) var volatileText: String = ""

    /// The caption exactly as shown in the bubble (confirmed + volatile tail). Used as the
    /// fallback transcription for very short clips, where the offline file model comes back
    /// empty even though this preview caught the words (#short-dictation).
    var liveCaption: String {
        [confirmedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    #if DEBUG
    /// Stages a caption without a live engine, for the indicator probe's screenshots and GIFs.
    func stageCaption(confirmed: String, volatile: String) {
        confirmedText = confirmed
        volatileText = volatile
    }
    #endif

    private let audioEngine = AVAudioEngine()
    private var manager: SlidingWindowAsrManager?
    private var updatesTask: Task<Void, Never>?
    private var feederTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private(set) var isRunning = false
    /// Bumped by every start()/cancel()/finish(). `start()` captures its value and bails out if
    /// it changes mid-setup — a stop can land before `isRunning` is even true (so cancel/finish
    /// no-op), and without this the half-set-up stream goes live as a zombie: it keeps feeding the
    /// old caption and its lingering `isRunning` blocks the next recording (#stale-caption).
    private var startGeneration = 0

    /// When the microphone last carried speech, for the stop phrase: the caption lags the
    /// voice by a second or so, so a phrase sitting at its end is only final once the room
    /// has gone quiet too (#145). Written from the audio thread.
    let voiceActivity = VoiceActivity()

    private init() {}

    /// Starts streaming. Throws if models/mic can't be set up — callers should fall back to the
    /// file-based flow. `boostTerms` (the custom dictionary's terms) bias recognition when present.
    func start(boostTerms: [String]) async throws {
        guard !isRunning else { return }
        startGeneration &+= 1
        let generation = startGeneration
        confirmedText = ""
        volatileText = ""

        let versionString = AppPreferences.shared.fluidAudioModelVersion
        let version = AsrModelVersion(preference: versionString)
        let models = try await AsrModels.downloadAndLoad(version: version)

        // Small windows so a rough preview appears quickly (the default 11–15s window emits
        // nothing for short dictations). First text lands at ~chunk+right ≈ 1.8s, then ~every
        // 1.5s. Intentionally lower quality — the inserted text comes from the accurate file
        // pass, not from here — so we trade accuracy for responsiveness.
        let previewConfig = SlidingWindowAsrConfig(
            chunkSeconds: 1.5,
            hypothesisChunkSeconds: 0.5,
            leftContextSeconds: 4.0,
            rightContextSeconds: 0.3,
            minContextForConfirmation: 1.0,
            confirmationThreshold: 0.80
        )
        let manager = SlidingWindowAsrManager(config: previewConfig)
        await configureVocabulary(on: manager, boostTerms: boostTerms)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .microphone)
        let updates = await manager.transcriptionUpdates

        // A stop (cancel/finish) or a newer start() may have landed during the async setup
        // above — before `isRunning` was true, so it no-op'd on us. Don't go live as a zombie:
        // tear the half-built stream down and return (#stale-caption).
        guard generation == startGeneration else {
            await manager.cancel()
            return
        }
        self.manager = manager

        updatesTask = Task { [weak self] in
            for await _ in updates {
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                await MainActor.run {
                    self?.confirmedText = confirmed
                    self?.volatileText = volatile
                }
            }
        }

        // The mic tap runs on the audio thread; it can't await the actor, so it yields buffers
        // into a stream that a single feeder task drains in order into `streamAudio`.
        let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.bufferContinuation = bufferContinuation
        feederTask = Task {
            for await buffer in bufferStream {
                await manager.streamAudio(buffer)  // any format → converted to 16k mono internally
            }
        }

        // `format: nil`, for the reason SpectrumAnalyzer spells out: a format read here goes stale
        // while the recorder is still taking the device, and the tap is refused. The manager
        // converts whatever arrives. The exception is caught for the same reason too — raised
        // inside this main-actor task, it would leave the app to crash on the next click.
        let input = audioEngine.inputNode
        do {
            try ObjCExceptionError.catching {
                let voiceActivity = self.voiceActivity
                voiceActivity.reset()
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                    voiceActivity.observe(buffer)
                    bufferContinuation.yield(buffer)
                }
            }
        } catch {
            await abandonStart(manager)
            throw error
        }
        do {
            try ObjCExceptionError.catching { audioEngine.prepare() }
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            await abandonStart(manager)
            throw error
        }
        isRunning = true
    }

    /// Undoes a start() that got as far as its tasks but never reached a running engine, so the
    /// caller's fallback to the file pass does not leave a feeder and a manager running behind it.
    private func abandonStart(_ manager: SlidingWindowAsrManager) async {
        stopAudio()
        await manager.cancel()
        self.manager = nil
    }

    /// Stops streaming and returns the complete transcript (nil if streaming wasn't running).
    func finish() async -> String? {
        startGeneration &+= 1  // abort any start() still in setup
        guard isRunning, let manager = manager else { return nil }
        stopAudio()
        let text = try? await manager.finish()
        self.manager = nil
        confirmedText = ""
        volatileText = ""
        return text
    }

    /// Stops and discards (used when a recording is cancelled).
    func cancel() async {
        startGeneration &+= 1  // abort any start() still in setup
        guard isRunning else { return }
        stopAudio()
        await manager?.cancel()
        manager = nil
        confirmedText = ""
        volatileText = ""
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        bufferContinuation?.finish()
        bufferContinuation = nil
        feederTask?.cancel()
        feederTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        isRunning = false
    }

    /// The weight FluidAudio's one-term-per-line loader gives every term, which the temporary
    /// vocabulary file this replaced went through.
    private static let boostWeight: Float = 10

    /// Loaded once, like the batch engine's: the tokenizer file is the same for every term list.
    private var ctcTokenizer: CtcTokenizer?

    /// Boosting is skipped, as with no terms, when the CTC models are unavailable on this OS
    /// build (`CtcModelLoader`). The models are the batch rescorer's, so the encoder compiles once.
    private func configureVocabulary(on manager: SlidingWindowAsrManager, boostTerms: [String]) async {
        let terms = boostTerms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        do {
            guard let models = try await CtcModelLoader.shared.models() else { return }
            let tokenizer = try await vocabularyTokenizer(for: models)
            // Built in code rather than through a temporary file, where a term containing ":"
            // or a leading "#" was read as the loader's own syntax.
            let vocabularyTerms = terms.compactMap { text -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(text)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: text, weight: Self.boostWeight, ctcTokenIds: ids)
            }
            guard !vocabularyTerms.isEmpty else { return }
            try await manager.configureVocabularyBoosting(
                vocabulary: CustomVocabularyContext(terms: vocabularyTerms), ctcModels: models)
        } catch {
            print("Streaming custom vocabulary unavailable: \(error)")
        }
    }

    private func vocabularyTokenizer(for models: CtcModels) async throws -> CtcTokenizer {
        if let ctcTokenizer { return ctcTokenizer }
        let tokenizer = try await CtcTokenizer.load(
            from: models.directory ?? CtcModels.defaultCacheDirectory(for: models.variant))
        ctcTokenizer = tokenizer
        return tokenizer
    }
}

import Foundation
import AVFoundation
import CoreAudioTypes

private class ProgressContext {
    var onProgress: ((Float) -> Void)?
    private var _lastReportedProgress: Float = 0.0
    private let lock = NSLock()
    
    var lastReportedProgress: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastReportedProgress
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastReportedProgress = newValue
        }
    }
}

public class WhisperEngine: TranscriptionEngine {
    var engineName: String { "Whisper" }
    
    /// Silero VAD, shipped in the app bundle (~0.9 MB). Used to cut non-speech audio out
    /// before the encoder sees it: long pauses aren't decoded at all, and silence can't be
    /// turned into invented text.
    static let vadModelPath: String? = CoreAccess.vadModelPath

    private var context: MyWhisperContext?
    private var vadContext: MyWhisperVadContext?
    private let stateLock = NSLock()
    private var _isCancelled = false
    private var _abortFlag: UnsafeMutablePointer<Bool>?
    private var progressContext: ProgressContext?

    /// When set, overrides the pref-selected model path — lets the remote local-fallback
    /// build an engine for a specific model without mutating global prefs. Readable so a test
    /// can check what the fallback factory passed.
    let modelPathOverride: String?
    private let vadModelFile: String?
    private let computePolicy: ComputePolicy

    init(modelPathOverride: String?, vadModelPath: String?, computePolicy: ComputePolicy) {
        self.modelPathOverride = modelPathOverride
        self.vadModelFile = vadModelPath
        self.computePolicy = computePolicy
    }

    public convenience init(modelPathOverride: String? = nil) {
        self.init(modelPathOverride: modelPathOverride, vadModelPath: WhisperEngine.vadModelPath,
                  computePolicy: CoreAccess.computePolicy)
    }
    
    private var isCancelled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCancelled
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCancelled = newValue
        }
    }
    
    private var abortFlag: UnsafeMutablePointer<Bool>? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _abortFlag
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _abortFlag = newValue
        }
    }
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        context != nil
    }
    
    public func initialize() async throws {
        try loadModel()
        // Opt-in RAM saver (#171): the model just validated, so free it (~1GB) until a
        // dictation actually needs it. Off by default — the model normally stays hot.
        if CoreAccess.preferences.unloadWhisperModelWhenIdle {
            unloadModel()
        }
    }

    private func loadModel() throws {
        let modelPath = modelPathOverride ?? CoreAccess.preferences.selectedWhisperModelPath ?? CoreAccess.preferences.selectedModelPath
        guard let modelPath = modelPath else {
            throw TranscriptionError.contextInitializationFailed
        }

        var params = WhisperContextParams()
        if computePolicy == .cpuOnly { params.useGPU = false }
        context = MyWhisperContext.initFromFile(path: modelPath, params: params)

        guard context != nil else {
            throw TranscriptionError.contextInitializationFailed
        }
    }

    private func unloadModel() {
        context = nil
    }

    public func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
        // With idle-unloading on, the model isn't held between dictations: load it on
        // demand here and release it again once this transcription finishes (#171).
        let unloadWhenIdle = CoreAccess.preferences.unloadWhisperModelWhenIdle
        if unloadWhenIdle && context == nil {
            try loadModel()
        }
        defer { if unloadWhenIdle { unloadModel() } }

        guard let context = context else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        isCancelled = false
        
        if abortFlag != nil {
            abortFlag?.deallocate()
        }
        abortFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        abortFlag?.initialize(to: false)
        
        // Setup progress context for callback
        progressContext = ProgressContext()
        progressContext?.onProgress = onProgressUpdate
        
        defer {
            abortFlag?.deallocate()
            abortFlag = nil
            progressContext = nil
        }
        
        // Notify conversion start (0-10% is conversion phase)
        onProgressUpdate?(0.05)
        
        guard let converted = try await AudioPCMConverter.convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }

        // Conversion done, now processing
        onProgressUpdate?(0.10)

        try Task.checkCancellation()

        // The VAD only ever *trims*: if it finds nothing, or can't run at all, the full clip
        // goes to whisper unchanged. Dropping a quiet sentence the VAD failed to hear costs
        // the user their words, while the silence it protects against is already handled by
        // suppressBlank and noSpeechThold. Timestamps are the exception: trimming shifts them
        // off the original file, so it's skipped when the user asked to see them.
        let samples: [Float]
        if settings.showTimestamps {
            samples = converted
        } else {
            let trimmed = Self.speechOnlySamples(
                from: converted, segments: detectSpeech(in: converted))
            samples = trimmed.isEmpty ? converted : trimmed
        }

        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        
        var params = WhisperFullParams()
        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        // Timestamp tokens are what advance whisper's sliding window: without them a window whose
        // decode ends early is neither retried nor rewound, and seek skips the rest of it (#115).
        params.noTimestamps = false
        params.suppressBlank = settings.suppressBlankAudio
        params.translate = settings.translateToEnglish
        let isAutoDetect = settings.selectedLanguage == "auto"
        params.language = isAutoDetect ? nil : settings.selectedLanguage
        params.detectLanguage = false // means that it only detects the language and does not process the transcription
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        let promptBoost = settings.shouldBoostCustomDictionary
            ? CustomDictionary.promptBoost(entries: settings.customDictionaryEntries)
            : ""
        // Read at record-start and carried on the clip, so a dictation queued behind another
        // cannot be handed the field the newer one was started in. (parallel-recording)
        let surrounding = TranscriptionPrompt.surroundingText(
            enabled: settings.useSurroundingTextAsContext,
            captured: settings.focusedText)
        let combinedPrompt = TranscriptionPrompt.combined(userPrompt: settings.initialPrompt,
                                                          dictionaryBoost: promptBoost,
                                                          surroundingText: surrounding) ?? ""
        params.initialPrompt = combinedPrompt.isEmpty ? nil : combinedPrompt
        // Otherwise the prompt only conditions the first 30s window, so a custom dictionary
        // stops being applied partway through a long dictation.
        params.carryInitialPrompt = !combinedPrompt.isEmpty

        typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool
        let abortCallback: GGMLAbortCallback = { userData in
            guard let userData = userData else { return false }
            let flag = userData.assumingMemoryBound(to: Bool.self)
            return flag.pointee
        }
        
        // Progress callback: whisper reports 0-100%, we map to 10-95%
        // Note: callback is called from C code, we need to bridge to Swift safely
        typealias WhisperProgressCallback = @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void
        let progressCallback: WhisperProgressCallback = { _, _, progressPercent, userData in
            guard let userData = userData else { return }
            let ctx = Unmanaged<ProgressContext>.fromOpaque(userData).takeUnretainedValue()
            // Map whisper progress (0-100) to our range (10-95%)
            let normalizedProgress = 0.10 + (Float(progressPercent) / 100.0) * 0.85
            // Report every progress update for smooth animation
            if normalizedProgress > ctx.lastReportedProgress {
                ctx.lastReportedProgress = normalizedProgress
                DispatchQueue.main.async {
                    ctx.onProgress?(normalizedProgress)
                }
            }
        }
        
        let progressContextPtr = Unmanaged.passUnretained(progressContext!).toOpaque()
        params.progressCallback = progressCallback
        params.progressCallbackUserData = progressContextPtr
        
        if settings.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.beamSize)
        }
        
        params.printRealtime = true
        params.print_realtime = true
        
        params.abortCallback = abortCallback
        
        if let abortFlag = abortFlag {
            params.abortCallbackUserData = UnsafeMutableRawPointer(abortFlag)
        }
        
        try Task.checkCancellation()
        
        guard context.full(samples: samples, params: &params) else {
            throw TranscriptionError.processingFailed
        }
        
        try Task.checkCancellation()
        
        var text = ""
        let nSegments = context.fullNSegments
        
        for i in 0..<nSegments {
            if i % 5 == 0 {
                try Task.checkCancellation()
            }
            
            guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
            
            if settings.showTimestamps {
                let t0 = context.fullGetSegmentT0(iSegment: i)
                let t1 = context.fullGetSegmentT1(iSegment: i)
                text += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
            }
            text += segmentText + (settings.showTimestamps ? "\n" : "")
        }
        
        let cleanedText = text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return TranscriptionPostProcessing.finish(cleanedText, settings: settings)
    }
    
    func cancelTranscription() {
        isCancelled = true
        if let abortFlag = abortFlag {
            abortFlag.pointee = true
        }
    }
    
    func getSupportedLanguages() -> [String] {
        return LanguageUtil.availableLanguages
    }

    // MARK: - VAD

    /// Speech regions in `samples`, or an empty array when the VAD is unavailable or found
    /// nothing. Deliberately non-throwing: a missing bundle resource or a failed context must
    /// degrade to transcribing the whole clip, not take the main engine down with it.
    ///
    /// Internal rather than private so a test can prove the engine's own VAD loads and trims:
    /// the transcript alone cannot show it, because a VAD that never loaded falls back silently.
    func detectSpeech(in samples: [Float]) -> [WhisperVadSegment] {
        if vadContext == nil {
            guard let path = vadModelFile,
                  let vad = MyWhisperVadContext(modelPath: path) else {
                return []
            }
            vadContext = vad
        }
        // whisper.cpp discards speech shorter than 250ms, which is about the length of "yes"
        // or "non" — fine when transcribing an hour of audio, wrong when someone is dictating
        // one.
        //
        // Padding stays at whisper.cpp's own value because its knob is symmetric, and the two
        // ends want opposite things: room before the first word, as little as possible after the
        // last. `speechOnlySamples` does that asymmetrically instead (#87).
        return vadContext?.speechSegments(in: samples, minSpeechMs: 100, padMs: 30) ?? []
    }

    /// Stitches the speech regions back into one buffer, mirroring what whisper.cpp does
    /// internally: each segment carries 0.1s of the audio that follows it, and segments are
    /// joined by 0.1s of silence so the decoder still hears a pause between phrases.
    static let vadSampleRate = 16000

    /// Kept before the first word. Whisper mistranscribes a word whose opening consonant is
    /// clipped, and the VAD's own boundary is tight.
    static let onsetPaddingMs = 150

    /// Kept between phrases, mirroring what whisper.cpp does when it stitches segments itself,
    /// so the decoder still hears a pause rather than two phrases welded together.
    static let interiorOverlapMs = 100

    /// Kept after the last word, and deliberately small. Trailing silence is what makes Whisper
    /// invent a closing phrase ("Thank you.", "Děkuji.") — reported against 0.11.0 on a clip
    /// where the VAD had found the speech correctly (#87). Our first version padded segments by
    /// 100ms on both sides *and* added 100ms of overlap to every segment end, so the tail carried
    /// 200ms of non-speech where whisper.cpp's own defaults carry 130ms. Widening the padding
    /// protected word onsets and made the end worse; the two ends want opposite things.
    static let tailPaddingMs = 20

    static func speechOnlySamples(from samples: [Float], segments: [WhisperVadSegment]) -> [Float] {
        // Degenerate segments are dropped first so "first" and "last" mean the first and last
        // ones actually kept, not positions in the VAD's raw output.
        let usable = segments.filter { $0.endCs > $0.startCs }
        guard !usable.isEmpty else { return [] }

        let rate = vadSampleRate
        let onset = onsetPaddingMs * rate / 1000
        let interior = interiorOverlapMs * rate / 1000
        let tail = tailPaddingMs * rate / 1000
        let gap = [Float](repeating: 0, count: interior)

        var result: [Float] = []
        result.reserveCapacity(samples.count)

        for (index, segment) in usable.enumerated() {
            let isFirst = index == 0
            let isLast = index == usable.count - 1

            let start = max(0, Int(segment.startCs) * rate / 100 - (isFirst ? onset : 0))
            let end = min(samples.count,
                          Int(segment.endCs) * rate / 100 + (isLast ? tail : interior))
            guard start < end else { continue }

            if !result.isEmpty {
                result.append(contentsOf: gap)
            }
            result.append(contentsOf: samples[start..<end])
        }

        return result
    }
}


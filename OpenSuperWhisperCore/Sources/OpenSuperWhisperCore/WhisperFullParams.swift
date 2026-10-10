//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperFullParams {
    var strategy: WhisperSamplingStrategy = .greedy
    var nThreads: Int32 = 1
    var nMaxTextCtx: Int32 = 16384
    var offsetMs: Int32 = 0
    var durationMs: Int32 = 0
    var translate: Bool = false
    var noContext: Bool = true
    var noTimestamps: Bool = false
    var singleSegment: Bool = false
    var printSpecial: Bool = false
    var printProgress: Bool = false
    var printRealtime: Bool = false
    var printTimestamps: Bool = true
    var tokenTimestamps: Bool = false
    var tholdPt: Float = 0.01
    var tholdPtsum: Float = 0.01
    var maxLen: Int32 = 0
    var splitOnWord: Bool = false
    var print_realtime: Bool = false
    var maxTokens: Int32 = 0
    var debugMode: Bool = false
    var audioCtx: Int32 = 0
    var tdrzEnable: Bool = false
    var suppressRegex: String?
    var initialPrompt: String?
    var carryInitialPrompt: Bool = false
    var promptTokens: [WhisperToken]?
    var language: String?
    var detectLanguage: Bool = false
    var suppressBlank: Bool = true
    var suppressNst: Bool = false
    var temperature: Float = 0.0
    var maxInitialTs: Float = 1.0
    var lengthPenalty: Float = -1.0
    var temperatureInc: Float = 0.2
    var entropyThold: Float = 2.4
    var logprobThold: Float = -1.0
    var noSpeechThold: Float = 0.6
    var greedyBestOf: Int32 = 1
    var beamSearchBeamSize: Int32 = 1
    var beamSearchPatience: Float = 0.0
    var newSegmentCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void)?
    var newSegmentCallbackUserData: UnsafeMutableRawPointer?
    var progressCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void)?
    var progressCallbackUserData: UnsafeMutableRawPointer?
    var encoderBeginCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Bool)?
    var encoderBeginCallbackUserData: UnsafeMutableRawPointer?
    var abortCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)?
    var abortCallbackUserData: UnsafeMutableRawPointer?
    var logitsFilterCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<whisper_token_data>?, Int32, UnsafeMutablePointer<Float>?, UnsafeMutableRawPointer?) -> Void)?
    var logitsFilterCallbackUserData: UnsafeMutableRawPointer?
    var grammarRules: [UnsafePointer<whisper_grammar_element>?]?
    var iStartRule: Int = 0
    var grammarPenalty: Float = 0.0

    init() {}

    mutating func toC() -> whisper_full_params {
        var cParams = whisper_full_params()

        cParams.strategy = whisper_sampling_strategy(rawValue: UInt32(strategy.rawValue))
        cParams.n_threads = nThreads
        cParams.n_max_text_ctx = nMaxTextCtx
        cParams.offset_ms = offsetMs
        cParams.duration_ms = durationMs
        cParams.translate = translate
        cParams.no_context = noContext
        cParams.no_timestamps = noTimestamps
        cParams.single_segment = singleSegment
        cParams.print_special = printSpecial
        cParams.print_progress = printProgress
        cParams.print_realtime = printRealtime
        cParams.print_timestamps = printTimestamps
        cParams.token_timestamps = tokenTimestamps
        cParams.thold_pt = tholdPt
        cParams.thold_ptsum = tholdPtsum
        cParams.max_len = maxLen
        cParams.split_on_word = splitOnWord
        cParams.print_realtime = print_realtime
        cParams.max_tokens = maxTokens
        cParams.debug_mode = debugMode
        cParams.audio_ctx = audioCtx
        cParams.tdrz_enable = tdrzEnable

        if let suppressRegex = suppressRegex {
            cParams.suppress_regex = UnsafePointer(strdup(suppressRegex))
        }

        if let initialPrompt = initialPrompt {
            cParams.initial_prompt = UnsafePointer(strdup(initialPrompt))
        }
        cParams.carry_initial_prompt = carryInitialPrompt

        if let promptTokens = promptTokens, !promptTokens.isEmpty {
            let count = promptTokens.count
            let ptr = UnsafeMutablePointer<WhisperToken>.allocate(capacity: count)
            ptr.initialize(from: promptTokens, count: count)
            cParams.prompt_tokens = UnsafePointer(ptr)
            cParams.prompt_n_tokens = Int32(count)
        }

        if let language = language {
            cParams.language = UnsafePointer(strdup(language))
        }

        cParams.detect_language = detectLanguage
        cParams.suppress_blank = suppressBlank
        cParams.suppress_nst = suppressNst
        cParams.temperature = temperature
        cParams.max_initial_ts = maxInitialTs
        cParams.length_penalty = lengthPenalty
        cParams.temperature_inc = temperatureInc
        cParams.entropy_thold = entropyThold
        cParams.logprob_thold = logprobThold
        cParams.no_speech_thold = noSpeechThold

        cParams.greedy.best_of = greedyBestOf
        cParams.beam_search.beam_size = beamSearchBeamSize
        cParams.beam_search.patience = beamSearchPatience

        if let callback = newSegmentCallback {
            cParams.new_segment_callback = callback
            cParams.new_segment_callback_user_data = newSegmentCallbackUserData
        }

        if let callback = progressCallback {
            cParams.progress_callback = callback
            cParams.progress_callback_user_data = progressCallbackUserData
        }

        if let callback = encoderBeginCallback {
            cParams.encoder_begin_callback = callback
            cParams.encoder_begin_callback_user_data = encoderBeginCallbackUserData
        }
        
        if let callback = abortCallback {
            cParams.abort_callback = callback
            cParams.abort_callback_user_data = abortCallbackUserData
        }

        if let callback = logitsFilterCallback {
            cParams.logits_filter_callback = callback
            cParams.logits_filter_callback_user_data = logitsFilterCallbackUserData
        }

        if let grammarRules = grammarRules, !grammarRules.isEmpty {
            let count = grammarRules.count
            let ptr = UnsafeMutablePointer<UnsafePointer<whisper_grammar_element>?>.allocate(capacity: count)
            ptr.initialize(from: grammarRules, count: count)
            cParams.grammar_rules = ptr
            cParams.n_grammar_rules = Int(count)
        }

        cParams.i_start_rule = Int(iStartRule)
        cParams.grammar_penalty = grammarPenalty

        return cParams
    }

    mutating func free() {
        var params = toC()
        whisper_free_params(&params)
    }
}

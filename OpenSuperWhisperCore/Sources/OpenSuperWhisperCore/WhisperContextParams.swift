//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperContextParams {
    var useGPU: Bool = true
    var flashAttention: Bool = true
    var gpuDevice: Int32 = 0
    var dtwTokenTimestamps: Bool = false
    var dtwAheadsPreset: WhisperAlignmentHeadsPreset = .none
    var dtwNTop: Int32 = 0
    var dtwAheads: WhisperAheads = .init(heads: [])
    var dtwMemSize: Int = 0 // remove

    init() {}

    func toC() -> whisper_context_params {
        var cParams = whisper_context_params()
        cParams.use_gpu = useGPU
        cParams.flash_attn = flashAttention
        cParams.gpu_device = gpuDevice
        cParams.dtw_token_timestamps = dtwTokenTimestamps
        cParams.dtw_aheads_preset = whisper_alignment_heads_preset(rawValue: UInt32(dtwAheadsPreset.rawValue))
        cParams.dtw_n_top = dtwNTop
        let swiftAheads = dtwAheads
        cParams.dtw_aheads = swiftAheads.toC() // Use the toC() method
        cParams.dtw_mem_size = dtwMemSize
        return cParams
    }
}
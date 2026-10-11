//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperTimings {
    let sampleMs: Float
    let encodeMs: Float
    let decodeMs: Float
    let batchdMs: Float
    let promptMs: Float

    init(sampleMs: Float, encodeMs: Float, decodeMs: Float, batchdMs: Float, promptMs: Float) {
        self.sampleMs = sampleMs
        self.encodeMs = encodeMs
        self.decodeMs = decodeMs
        self.batchdMs = batchdMs
        self.promptMs = promptMs
    }

    static func fromC(_ cTimings: whisper_timings) -> WhisperTimings {
        return WhisperTimings(sampleMs: cTimings.sample_ms,
                              encodeMs: cTimings.encode_ms,
                              decodeMs: cTimings.decode_ms,
                              batchdMs: cTimings.batchd_ms,
                              promptMs: cTimings.prompt_ms)
    }
}
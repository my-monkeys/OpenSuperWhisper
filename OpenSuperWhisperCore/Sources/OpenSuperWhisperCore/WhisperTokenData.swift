//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperTokenData {
    let id: WhisperToken
    let tid: WhisperToken
    let p: Float
    let plog: Float
    let pt: Float
    let ptsum: Float
    let t0: Int64
    let t1: Int64
    let tDtw: Int64
    let vlen: Float

    init(id: WhisperToken, tid: WhisperToken, p: Float, plog: Float, pt: Float, ptsum: Float, t0: Int64, t1: Int64, tDtw: Int64, vlen: Float) {
        self.id = id
        self.tid = tid
        self.p = p
        self.plog = plog
        self.pt = pt
        self.ptsum = ptsum
        self.t0 = t0
        self.t1 = t1
        self.tDtw = tDtw
        self.vlen = vlen
    }

    static func fromC(_ cData: whisper_token_data) -> WhisperTokenData {
        return WhisperTokenData(id: cData.id,
                                tid: cData.tid,
                                p: cData.p,
                                plog: cData.plog,
                                pt: cData.pt,
                                ptsum: cData.ptsum,
                                t0: cData.t0,
                                t1: cData.t1,
                                tDtw: cData.t_dtw,
                                vlen: cData.vlen)
    }
}
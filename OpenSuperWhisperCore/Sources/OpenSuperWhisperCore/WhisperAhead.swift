//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperAhead {
    let nTextLayer: Int32
    let nHead: Int32

    init(nTextLayer: Int32, nHead: Int32) {
        self.nTextLayer = nTextLayer
        self.nHead = nHead
    }

    func toC() -> whisper_ahead {
        return whisper_ahead(n_text_layer: nTextLayer,
                             n_head: nHead)
    }

    static func fromC(_ cAhead: whisper_ahead) -> WhisperAhead {
        return WhisperAhead(nTextLayer: cAhead.n_text_layer,
                            nHead: cAhead.n_head)
    }
}
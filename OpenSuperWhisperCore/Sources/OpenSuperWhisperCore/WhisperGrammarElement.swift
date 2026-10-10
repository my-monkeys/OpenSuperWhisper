//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperGrammarElement {
    let type: WhisperGrammarElementType
    let value: UInt32

    init(type: WhisperGrammarElementType, value: UInt32) {
        self.type = type
        self.value = value
    }

    func toC() -> whisper_grammar_element {
        return whisper_grammar_element(type: whisper_gretype(rawValue: UInt32(type.rawValue)),
                                       value: value)
    }
}
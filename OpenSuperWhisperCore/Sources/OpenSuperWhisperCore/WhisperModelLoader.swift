//
// Created by user on 07.02.2025.
//

import Foundation
internal import OSWNative

struct WhisperModelLoader {
    var context: UnsafeMutableRawPointer?
    var read: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Int)?
    var eof: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)?
    var close: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?

    init(context: UnsafeMutableRawPointer? = nil, read: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Int)? = nil, eof: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)? = nil, close: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil) {
        self.context = context
        self.read = read
        self.eof = eof
        self.close = close
    }

    func toC() -> whisper_model_loader {
        return whisper_model_loader(context: context,
                                    read: read,
                                    eof: eof,
                                    close: close)
    }
}
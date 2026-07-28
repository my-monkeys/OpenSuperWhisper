//
//  Bridge.h
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

#include "whisper.h"
#include "asian-autocorrect/autocorrect-swift/autocorrect_swift.h"
#include "sherpa-onnx/c-api/c-api.h"
// llama.cpp built-in LLM backend. HEADER_SEARCH_PATHS names libwhisper/llama.cpp/include
// explicitly — NOT recursively, and not the llama.cpp root: the tree ships
// common/jinja/string.h, which a recursive entry would let shadow the system <string.h> and
// break every Clang module build ("'optional' file not found"). llama.h's own ggml includes
// resolve from whisper.cpp's ggml headers, which are the shared ggml.
#include "llama.h"

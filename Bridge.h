//
//  Bridge.h
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

#include "whisper.h"
#include "asian-autocorrect/autocorrect-swift/autocorrect_swift.h"
#include "sherpa-onnx/c-api/c-api.h"
// llama.cpp built-in LLM backend. Header lives at libwhisper/llama.cpp/include/llama.h,
// which is covered by the recursive HEADER_SEARCH_PATHS entry $(PROJECT_DIR)/libwhisper/**.
#include "llama.h"

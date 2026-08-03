//
//  LlamaBridge.h
//  OpenSuperWhisper
//
//  App-side bridging header for the llama.cpp C API consumed by
//  Llama/LlamaContext.swift (the built-in LLM cleanup backend). This is the
//  app-side successor to the llama portion of the pre-extraction Bridge.h:
//  whisper/sherpa/autocorrect imports moved into clang modulemaps consumed by
//  WhisperCore (framework targets cannot use bridging headers; app targets
//  can), while the llama stack stays app-side per the protocol-inversion
//  ruling (PR #57) — libllama.a + the GGUF model are desktop-only weight that
//  never enters the iOS-shared framework.
//
//  HEADER_SEARCH_PATHS names libwhisper/llama.cpp/include
//  explicitly — NOT recursively, and not the llama.cpp root: the tree ships
//  common/jinja/string.h, which a recursive entry would let shadow the system
//  <string.h> and break every Clang module build ("'optional' file not
//  found"). llama.h's own ggml includes resolve from whisper.cpp's ggml
//  headers, which are the shared ggml.
//

#ifndef LlamaBridge_h
#define LlamaBridge_h

#include "llama.h"

#endif /* LlamaBridge_h */

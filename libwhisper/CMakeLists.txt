# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libwhisper)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# Disable i8mm/MATMUL_INT8 to fix compilation on GitHub Actions runners
# The feature detection passes but compilation fails with the newer Xcode toolchain
# Undefine the feature macro to prevent i8mm intrinsics from being used
add_compile_definitions(GGML_MATMUL_INT8=0)
add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)

add_subdirectory(whisper.cpp)

# --- llama.cpp (built-in local LLM cleanup backend) ---
# whisper.cpp (above) already did add_subdirectory(ggml) and created the `ggml`
# target. llama.cpp's own add_subdirectory(ggml) is guarded by `if (NOT TARGET ggml)`,
# so adding llama.cpp AFTER whisper.cpp makes both SHARE the single ggml target and
# avoids duplicate-symbol link errors. Order here is load-bearing — do not move
# llama.cpp before whisper.cpp.
#
# Pinned llama.cpp tag: b9878 (2026-07-05), chosen to match whisper.cpp v1.9.1's
# vendored ggml — the public ggml headers (ggml/include/*.h) are byte-identical
# between the two checkouts. That match is a HARD requirement, not a nicety: llama's
# sources compile against whisper's ggml headers, so a mismatched pin fails outright
# (an older llama.cpp expected the long-gone `GGML_KQ_MASK_PAD` macro). Whenever
# either submodule is bumped, pick a llama.cpp tag from the same ggml era and
# re-verify with:
#   diff -rq whisper.cpp/ggml/include llama.cpp/ggml/include
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL           OFF CACHE BOOL "" FORCE)
# We share whisper.cpp's ggml; don't let llama re-add or re-build it.
set(LLAMA_BUILD_COMMON   OFF CACHE BOOL "" FORCE)

add_subdirectory(llama.cpp)

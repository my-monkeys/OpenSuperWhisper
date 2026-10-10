# Extracting the transcription core

Status: in progress on `refactor/core-package`. Supersedes the framework-target approach of
PR #57 (WhisperCore), whose design decisions are reused where they still fit. Goal: one
transcription core shared by the macOS app and a future iPhone app (issue #52), with no
behaviour change for the macOS app.

## Reference behaviour

"No regression" is measured against two references, because dev builds and shipped builds
differ today:

| Reference | How it is built | Used for |
|---|---|---|
| Test suite | `xcodebuild test` with `-derivedDataPath build -clonedSourcePackagesDirPath SourcePackages` (patched FluidAudio) | Every slice: the per-test pass/skip list of master (710 passed, 9 skipped on 47fe26b) must be reproduced, plus the new tests |
| Shipped app | `notarize_app.sh` (universal libwhisper configure, `GGML_NATIVE=OFF`, so generic ggml CPU kernels; unpatched FluidAudio) | Release smoke check before merging: load commands, embedded files, `jfk.wav` transcription identical to 0.13.3 |

Two known divergences are kept as they are and listed as follow-ups, not fixed here: releases
ship FluidAudio without `patches/fluidaudio-vocabulary-rescorer.patch`, and the release ggml
CPU backend is built in generic mode.

## Packaging

A local Swift package, `OpenSuperWhisperCore/`, referenced from the Xcode project the same way
`LiquidGlass/` is (`XCLocalSwiftPackageReference`). Not a framework target:

- One native build path for every platform. whisper.cpp, llama.cpp and their shared ggml come
  out of a single CMake configure of `libwhisper/` and are packaged as one static xcframework.
  Two ggml copies (whisper's and llama's) in one process are ruled out: duplicate symbols or
  silent ODR mixing, and llama's copy lacks the fork's Metal teardown fix.
- Static linking into the app image, so GRDB, FluidAudio and ggml each exist once per process.
  PR #57's dynamic framework needed GRDB-dynamic plus an embed script, and still linked
  FluidAudio twice.
- The package compiles for macOS 14 and iOS 17 and can be tested on its own (xcodebuild on
  macOS and the iOS Simulator).

Package settings that are not negotiable:

- `swiftLanguageModes: [.v5]` and no upcoming-feature flags: the app compiles in Swift 5 mode
  and the move must not change isolation or async execution semantics.
- Same exact versions as the app for shared dependencies (FluidAudio 0.17.5, GRDB 7.5.0+), so
  the workspace resolves one checkout and run.sh keeps patching it.
- C modules are imported with `internal import`, so no C type appears in the public API and
  consumers need no header paths.

## Native binaries

`Scripts/build-native.sh [macos|ios|all]` (macOS only by default) builds into
`OpenSuperWhisperCore/Binaries/` (gitignored, outside `build/`, which the release scripts
delete):

- `OSWNative.xcframework`, static, whisper + llama + ggml from ONE configure of `libwhisper/`:
  `cmake -G Xcode -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF`, built in Release, archives merged with
  `libtool -static` (never `ld -r`: the whisper symbols are private externs). macOS slice
  `arm64;x86_64` at 14.0, which is exactly how `notarize_app.sh` builds the shipped binary;
  iOS arm64 and iOS Simulator arm64 at 17.0 (`CMakeLists.txt` must stop forcing 14.0). Headers
  and module map live under `Headers/OSWNative/` (module `OSWNative`, links c++, Accelerate,
  Metal, Foundation), so nothing lands flat in the shared `include/`.
- `SherpaOnnx.xcframework`: the existing macOS static library, module map moved to
  `Headers/sherpa_onnx/`. macOS only for now. onnxruntime stays linked by the app
  (`OTHER_LDFLAGS[arch=arm64]`), never by the package: SwiftPM cannot condition a link on the
  architecture, and the Intel build must not load it.
- The stamp covers: submodule SHAs and their uncommitted diff, `libwhisper/CMakeLists.txt`,
  the script, `xcodebuild -version`, `cmake --version`, the configure arguments and the
  platform set. `FORCE=1` rebuilds. Release builds always force.
- Gate for the swap: symbol lists and sizes of the new macOS slice match the Release archives
  of today's subproject for both architectures; `nm -m` on the app shows a single
  `_whisper_full` and `_ggml_backend_metal_reg` (`_ggml_backend_metal_init` is dead-stripped
  from today's app already, so it cannot be the marker).
- Measured in slice 1 (Xcode 27.0 27A266a, CMake 4.3.2, whisper.cpp 580b3c5, llama.cpp
  2da6686): the macOS slice was compared with a reference built the way `notarize_app.sh` does
  (`cmake -G Xcode -DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`, then
  `xcodebuild -configuration Release` on the seven targets). Per architecture, all 197 archive
  members are byte-identical (24375 defined symbols on arm64, 15123 on x86_64, private externs
  included), the generated Xcode projects are identical apart from object IDs and the build
  directory, and ggml-cpu is compiled with `-DGGML_CPU_GENERIC` in both. The only configure
  difference is `GGML_OPENMP=OFF` instead of a NOTFOUND OpenMP; neither build has an OpenMP
  symbol.

Consequence, accepted on purpose: Debug builds and the test suite switch from native-kernel,
-O0 ggml to the shipped configuration (generic kernels, Release). This closes a divergence
instead of adding one. The Whisper goldens are recorded under both configurations in slice 0
so the switch is measured, not assumed. Measured: the goldens are byte-identical under
run.sh's native-kernel -O0 build, the generic-kernel universal configure at -O0, and that
configure with `CMAKE_{C,CXX}_FLAGS_DEBUG='-O3 -DNDEBUG'` (Apple Silicon, Metal, Xcode 27.0);
the exact VAD pins match under the first and the last. A golden that breaks in slice 1 or 2
therefore points at the move itself, not at the optimisation level.

Entry points call the script before package resolution (a missing binary target breaks
resolution): `run.sh`, CI (cache keyed on the stamp inputs), `notarize_app.sh` (after its
`rm -rf build`). A fresh clone runs `./run.sh build` before opening Xcode. libomp, which
nothing uses (OpenMP is NOTFOUND in the CMake cache), disappears everywhere: link flag,
embed, search path, scripts, CI.

## What moves, what stays

Moves to the core (macOS + iOS): the `TranscriptionEngine` protocol and the Whisper,
FluidAudio, Apple Speech and Remote engines; the whisper and llama wrappers; audio conversion
and voice activity; post-processing, the custom dictionary and the pure text cleanup steps;
LLM cleanup (protocol, Ollama, Remote, built-in llama); the model managers and the model
catalogs (extracted from `Settings.swift`); the transcription service; recording storage and
the transcription queue (its NSAlert becomes an injected consent closure, which also removes
`RecordingStore`'s call into the queue); `DefaultsStore`, the `UserDefault` wrappers,
`Keychain`, `AppIdentity`, `TranscriptionResult`, `TranscriptionError`.

A separate macOS-only target `OSWSenseVoice` holds sherpa-onnx and the SenseVoice engine and
model manager; the core depends on it with `.when(platforms: [.macOS])`, and the
`#if arch(arm64)` gates become `#if os(macOS) && arch(arm64)` (identical on macOS).

Stays in the app: everything AppKit, audio capture and device handling (including
`StreamingTranscriptionController`, which owns the mic tap and its ObjCException guard), text
insertion, triggers and shortcuts, the indicator, agents, Sparkle, `DictationPipeline`
(macOS outputs) and the Rust autocorrect library (no iOS build yet).

Every `@available`/`#available(macOS 26.0, *)` that moves becomes
`(macOS 26.0, iOS 26.0, *)`. From slice 1 on, every slice builds the package for
`generic/platform=iOS Simulator`, so macOS-only API cannot creep into the core.

## Seams

Core types take their dependencies through their initialisers (preferences, storage root,
VAD model URL, text formatter, compute policy), so the iPhone app and the core tests build
them directly. The macOS app keeps its singletons and call sites: a `CoreConfiguration` is
installed once at the top of `AppMain.main`, and the core's `.shared` instances are built
lazily from it.

- `preferences` is a lazy provider (`{ AppPreferences.shared }`): installing it touches
  nothing, so the AppPreferences migrations keep running at their current moment in the GUI,
  the CLI and the agent hook. The protocol is class-bound and not actor-isolated, lists every
  member the core reads or writes, and `AppPreferences` conforms with the same keys and
  storage. Keychain-backed members stay computed on `AppPreferences`.
- `textFormatter`: the app installs the Rust autocorrect; a host without one gets the text
  unchanged.
- `storageRoot`: the macOS app passes `AppIdentity.storageRoot()`, which is the pinned
  `applicationSupportDirectory()` formula in a normal launch (whisper model paths are persisted
  as absolute strings) and a per-process temp directory under XCTest. The iPhone
  app will store file names and resolve them against its root, because its container path
  changes across updates.
- `vadModelURL`: the macOS app passes today's `Bundle(for: WhisperEngine.self)` lookup, which
  stays symlink-safe for the Homebrew CLI. The package ships no resources.
- `computePolicy` (`.automatic` = today; `.cpuOnly` for iPhone background work, where Metal
  is forbidden).

Reading the configuration before it is installed traps with a clear message, except in
SwiftUI previews and under a DEBUG-only replaceable install used by core tests. The storage is
lock-protected (OSAllocatedUnfairLock), not a bare mutable global.

`Settings` becomes the core value type `TranscriptionSettings` with a public memberwise init.
The app keeps `typealias Settings = TranscriptionSettings` and an extension with today's
`init()` and the prompt-file statics (macOS paths). The core type is not called `Settings`,
which would clash with `SwiftUI.Settings` in every app file.

Access control: public is the surface the macOS UI and the iPhone app need (engines through
the service, `DictationModelOption`, `Recording`, `RecordingStore`, the queue, model
managers, catalogs, LLM status, settings). Everything else stays internal; tests add
`@testable import OpenSuperWhisperCore` file by file, and in slices 2 to 4 the only change
allowed in existing test files is an added import line or a fixture path.

The hosted test target never links the core product: it reaches the core through the host
(`BUNDLE_LOADER`), like it already does for FluidAudio and LiquidGlass. A second static copy
would duplicate every singleton and silently disable VAD in tests. Gated by a test
(`Bundle(for: WhisperEngine.self) == Bundle.main`) and by failing on "is implemented in both".

## Persisted contracts that must not change

UserDefaults keys and store (`DefaultsStore.current`), Keychain service, accounts and query
attributes, GRDB migration identifiers (copied literally), Application Support directory
names and the exact path formula, engine identifiers (`whisper`, `fluidaudio`, `sensevoice`,
`remote`, `apple`), Parakeet version values (`v2`, `v3`, `ultra`), the
`TranscriptionResult.noSpeech` string, notification raw names, the os_log subsystem. Each is
pinned by a slice-0 test before anything moves.

## Slices

Each slice builds (Debug, Release, x86_64 Release, iOS Simulator once the package exists),
passes the full suite, and goes through an adversarial review before the next one starts.

0. Groundwork, no move.
   - Isolation: a second test-detection signal (`NSClassFromString("XCTestCase")`); under
     tests the storage root (recordings DB and folder, model folders) moves to a per-process
     temp directory like the defaults suite already does; the queue, the retention scheduler
     and hotkey registration do not start in the test host; the two tests that write the real
     defaults domain use `DefaultsStore.current`; the Whisper prompt file resolves inside the
     test storage root. Known residual: KeyboardShortcuts can only use `UserDefaults.standard`,
     so the trigger views (`TriggerRecorderField`, `ContentView`, `AgentPanel`) still read the
     user's real bindings when tests render them. The only write there is the library filling
     in a declared default when its key is absent, and the trigger migration no longer copies
     the real bindings into the test suite.
   - Characterization tests: Whisper golden on `jfk.wav` with `ggml-tiny.en.bin` (and with
     timestamps), recorded under both ggml configurations; VAD actually used on the engine
     path (padded clip is trimmed) and resolved from the app bundle; no-speech on silence;
     engine factory mapping; persisted strings (notification names, Keychain service and
     accounts, engine ids, Parakeet versions, no-speech marker, log subsystem); a snapshot of
     every UserDefaults key; the path formulas; RecordingStore migrations (identifiers, a
     fixture database made by 0.13.3, schema snapshot, round trip); AppPreferences migrations
     from legacy keys; `Settings()` resolution order; LLM request bodies and fallbacks;
     Remote engine request; repeated load and unload of whisper and llama contexts.
   - Tooling: drop the dangling `WhisperCppBindingTests` scheme entry; CLI flags `--model`
     and `--raw` for a deterministic smoke check; `Scripts/smoke-release.sh` (both
     architectures, app path and Homebrew-style symlink, VAD load line, Metal init, exit
     code with a model loaded, one ggml, no libomp, signature); CI runs the unit tests
     (serially, timing-sensitive host tests skipped) and an x86_64 Release build.
     The Whisper goldens and the exact VAD boundaries are only promised on an Apple Silicon
     Mac with its Metal GPU: `Fixtures.requireGoldenMachine()` skips them on another arch, with
     no Metal device or a GPU outside the Apple families, and when
     `TEST_RUNNER_OSW_GOLDEN_MACHINE=0` is set, which CI sets unless its runner is known to
     match. The llama lifecycle test reads its model only from `TEST_RUNNER_OSW_TEST_GGUF` and
     skips without it; the required-tests check sets it, so the llama half cannot drop out
     unnoticed.
1. Native build script and an empty core package wired into the app (Debug, Release,
   x86_64, iOS Simulator), proving module lookup without linking any native symbol from it,
   hosted `@testable` access, and no duplicate copy in the test bundle.
2. One atomic swap: the whisper, llama and sherpa wrappers move to the core, the app drops
   the libwhisper subproject, its seven proxies, the direct sherpa link, the native header
   paths and libomp; `Bridge.h` keeps autocorrect and ObjCException.
3. `CoreConfiguration`, `TranscriptionSettings`, and the pure models and helpers.
4. Engines, LLM cleanup, model managers and catalogs, the transcription service, recording
   storage and the queue.
5. Core test target (macOS and iOS Simulator, run with the patched FluidAudio checkout);
   tests move with a committed rename map; the total may only grow.
6. The first iPhone app: record in the foreground, transcribe on device (Parakeet, Apple
   Speech on iOS 26) or remotely, clean up, copy and share, history. Models excluded from
   backup. `make_release.sh` scoped to the macOS target first.

## Follow-ups kept out of the extraction

Each is a behaviour change and gets its own PR with a test: the FluidAudio boost path loading a second model set per call; FluidAudio `versionOverride`
ignored when boosting (`FluidAudioEngine` L130, L154); `applyOneOffModel` writing persisted
preferences; the main-window recorder bypassing `DictationPipeline`; shipping the FluidAudio
patch in releases (ideally via a fork tag); native ARM kernels in releases; integrity checks
on model downloads; API keys sent over plain http; the remote local-fallback factory
(`fallbackEngineChoice`) handing an option's identifier to Whisper as a model path for
SenseVoice on Intel (`"default"`) and for any engine it does not know (`"remote"` included),
and building the selected Whisper model for `"apple"` below macOS 26.

Credit: the module maps, the iOS xcframework flags, the consent seam and several tests come
from PR #57 by @michael-wojcik.

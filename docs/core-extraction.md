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
| Shipped app | `notarize_app.sh` (whisper, llama and ggml from `FORCE=1 Scripts/build-native.sh`, `GGML_NATIVE=OFF`, so generic ggml CPU kernels, as the universal libwhisper configure it replaced in slice 2; unpatched FluidAudio) | Release smoke check before merging: load commands, embedded files, `jfk.wav` transcription identical to the current references, `docs/smoke/post-swap-<arch>.txt` since slice 2 (below) |

The release smoke check is `Scripts/build-release-unsigned.sh <arch>` (`notarize_app.sh` up to
signing) followed by `Scripts/smoke-release.sh <app> --expect docs/smoke/post-swap-<arch>.txt`,
for arm64 and for x86_64 (under Rosetta). The `pre-swap-<arch>.txt` files were slice 2's
baseline. 0.13.3 cannot be the reference, because its CLI has no `--model` and `--raw`, so the
first references were recorded from slice 0 (f7444b0) on an Apple M5 Pro
with Xcode 27.0 (27A266a). Their transcripts and VAD segments only hold on that Mac; the load
commands, rpaths, frameworks, symbol counts and resources hold on any Mac with that Xcode. The
one difference allowed is slice 2's: libomp goes, so the `@rpath/libomp.dylib` load command and
`libomp.dylib` leave the report and its libomp line reads "linked no, embedded no". Slice 2
recorded the references again as `docs/smoke/post-swap-<arch>.txt`; later slices compare against
those, with no difference allowed.

Running the Release binary as a CLI for the check is safe on a developer's Mac: `CLI.run`
creates `NSApplication` only to set the `.prohibited` activation policy, and never runs
`AppDelegate`, the windows or the hotkeys (the headless mode Homebrew installs). `--model` and
`--raw` keep the user's engine, model, prompt and dictionary out of the run. The one preference
still read is "Unload model when idle" (`unloadWhisperModelWhenIdle`): with it on the CLI exits
with no context loaded, so `smoke-release.sh` refuses to run and leaves the setting to the user.

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
- The iOS slices get baseline arm64 CPU kernels (no `GGML_CPU_ARM_ARCH`). ggml chooses them at
  compile time with no runtime dispatch, and iOS 17 still runs on the A12 (no dot product)
  and iPadOS 17 on the A10 (no fp16 vector arithmetic), where an iPhone app also runs. The
  script fails if such instructions show up in the iOS device slice. Faster kernels need a
  device floor that rules those chips out (dot product starts with the A13, and iPadOS 26 still
  runs on A12 iPads), decided with the iPhone app.
- The iOS Simulator slice has no x86_64. A static library is never linked, so the package
  builds for `generic/platform=iOS Simulator` anyway, but anything that links it there (core
  tests, the iPhone app) builds with `ARCHS=arm64`.
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
  symbol. One thing this comparison could not see: built inside the app's xcodebuild, as
  `notarize_app.sh` does, the subproject also got Xcode's coverage instrumentation (slice 2).

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

A separate target `OSWSenseVoice` holds sherpa-onnx and the SenseVoice engine and model
manager. It links the sherpa binary target with `.when(platforms: [.macOS])` and its sources sit
behind `#if os(macOS) && arch(arm64)` (identical to today's `#if arch(arm64)` on macOS), so it
compiles to an empty module elsewhere and the core depends on it unconditionally while still
building for iOS.

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
     code with a model loaded, one ggml, libomp and onnxruntime per architecture, signature).
     The signature is only verified on a signed app, that is `notarize_app.sh`'s output: the
     unsigned builds of `build-release-unsigned.sh`, the references included, skip it, so the
     check runs once on a signed build before slice 2 merges.
     CI runs the unit tests serially and an unsigned x86_64 Release build. It skips only the
     tests that switch the system keyboard layout; the Bluetooth microphone and notch tests
     skip themselves without the hardware. Changed from the first plan, which also skipped the
     timing-sensitive host tests: CI runs them, retries a failing test once
     (`-retry-tests-on-failure -test-iterations 2`) and names in the job summary any test that
     only passed on the retry. ErrorFeedbackTests and ClipboardRestoreTests schedule their
     timers and their checks on the same main queue, so they should hold on a slow VM, and a
     retry shows when they do not.
     The Whisper goldens and the exact VAD boundaries are only promised on an Apple Silicon
     Mac with its Metal GPU: `Fixtures.requireGoldenMachine()` skips them on another arch, with
     no Metal device or a GPU outside the Apple families, and when
     `TEST_RUNNER_OSW_GOLDEN_MACHINE=0` is set, which CI sets unless its runner is known to
     match. That skips every test that runs Whisper (the context lifecycle included), so CI
     does not exercise Whisper inference. The llama lifecycle test reads its model only from
     `TEST_RUNNER_OSW_TEST_GGUF` and skips without it: the llama half runs only when a
     developer sets it locally, and CI lists it among the skipped tests in its job summary.
1. Native build script and an empty core package wired into the app (Debug, Release,
   x86_64, iOS Simulator), proving module lookup without linking any native symbol from it,
   hosted `@testable` access, and no duplicate copy in the test bundle.
2. One atomic swap: the whisper, llama and sherpa wrappers move to the core, the app drops
   the libwhisper subproject, its seven proxies, the direct sherpa link, the native header
   paths and libomp; `Bridge.h` keeps autocorrect and ObjCException.
   Done: the wrappers are public only where the app's remaining code calls them, and no C type
   reaches the public API, so every C module stays an `internal import` (no transitional
   `public import`). Two small seams made that possible: `MyWhisperContext.full(samples:params:)`
   takes the Swift `WhisperFullParams`, abort callback included, and `SenseVoiceRecognizer` in
   `OSWSenseVoice` builds the sherpa configuration the engine used to build. `LanguageUtil`
   stays in the app and reads the language table through `MyWhisperContext`'s existing static
   wrappers. Measured against a Release build of the slice-1 commit, arm64 and x86_64: the load
   commands and the `Frameworks`/`Resources` listings differ only by libomp, the app defines
   `_whisper_full`, `_llama_backend_init` and `_ggml_backend_metal_reg` once, onnxruntime is
   loaded on arm64 only, and the binary is about 4 MB smaller (4.1 MB on arm64, 3.7 MB on
   x86_64). A small part of that is wrapper methods nobody calls, now internal and
   dead-stripped with the C functions they referenced. Most of it is coverage instrumentation:
   `CLANG_COVERAGE_MAPPING` and `ENABLE_CODE_COVERAGE` resolve to YES for this scheme even in
   Release (`xcodebuild -showBuildSettings -scheme OpenSuperWhisper -configuration Release`),
   and Xcode applied them to the libwhisper subproject, so the slice-1 Release build and the
   0.13.3 release compiled ggml, whisper and llama with `-fprofile-instr-generate
   -fcoverage-mapping`. The flags sit in each target's `*-common-args.resp`, not on the
   CompileC line, which is why the command lines looked identical. OSWNative is not
   instrumented, so the swap removes the coverage counters from ggml's hot loops in shipped
   builds: 0.13.3's arm64 binary holds 142 ggml `__profc_` counters, the swapped one none.
   On arm64, `__llvm_covfun` goes from 2754864 to 824166 bytes, `__llvm_prf_cnts` from 538336
   to 246056, `__llvm_prf_data` from 1223360 to 916800 and `__llvm_prf_names` from 840763 to
   488485. The instrumentation also explains the inlining difference: the exact slice-1
   compile of `ggml.c` inlines `ggml_add_impl` into `ggml_add` with the two flags and not
   without them.
   Floating-point semantics do not change. The goldens and VAD pins are unchanged on Apple
   Silicon, and the x86_64 CPU kernels, which nothing else exercises, give byte-identical
   results: a small C program transcribing `jfk.wav` (tiny.en, greedy, 4 threads, token
   timestamps) and running the Silero VAD over it, under Rosetta, prints the same VAD
   boundaries, segment times, token ids and token probabilities linked against OSWNative's
   x86_64 slice and against an x86_64 build of the subproject with Xcode's coverage settings,
   on the CPU backend (with BLAS) and on Metal. That does not replace the pre-merge release smoke
   check, which ran once slice 0's `--model`/`--raw` flags were in: `build-release-unsigned.sh`
   then `smoke-release.sh --expect docs/smoke/pre-swap-<arch>.txt`, arm64 and x86_64 (under
   Rosetta), on the Mac and Xcode that recorded the references. Both reports differ from them
   only by libomp: the `@rpath/libomp.dylib` load command, `libomp.dylib` on the frameworks
   line, and "libomp: linked no, embedded no". Transcripts, VAD segments, Metal, exit codes,
   rpaths, onnxruntime per architecture, the single `_whisper_full` and
   `_ggml_backend_metal_reg`, and the VAD resource are unchanged. The new reports are
   `docs/smoke/post-swap-<arch>.txt`. Still to do on a signed build: the signature check,
   which the unsigned builds skip.
3. `CoreConfiguration`, `TranscriptionSettings`, and the pure models and helpers.
4. Engines, LLM cleanup, model managers and catalogs, the transcription service, recording
   storage and the queue.
5. Core test target (macOS and iOS Simulator, run with the patched FluidAudio checkout);
   tests move with a committed rename map; the total may only grow.
The extraction stops there. The iPhone app itself (issue #52) is a later project; until then
the core only has to keep building for iOS, which every slice checks. Notes for that
project: record in the foreground, transcribe on device (Parakeet, Apple Speech on iOS 26)
or remotely, exclude models from backup, and scope `make_release.sh` to the macOS target
before an iOS target joins the project.

## Follow-ups kept out of the extraction

Each is a behaviour change and gets its own PR with a test: the FluidAudio boost path loading a second model set per call; FluidAudio `versionOverride`
ignored when boosting (`FluidAudioEngine` L130, L154); `applyOneOffModel` writing persisted
preferences; the main-window recorder bypassing `DictationPipeline`; shipping the FluidAudio
patch in releases (ideally via a fork tag); native ARM kernels in releases; integrity checks
on model downloads; API keys sent over plain http; the remote local-fallback factory
(`fallbackEngineChoice`) handing an option's identifier to Whisper as a model path for
SenseVoice on Intel (`"default"`) and for any engine it does not know (`"remote"` included),
and building the selected Whisper model for `"apple"` below macOS 26; Release builds still
instrumenting all Swift code (the app, OpenSuperWhisperCore, OSWSenseVoice, FluidAudio, GRDB,
KeyboardShortcuts, LiquidGlass), the app's Objective-C and FluidAudio's C targets for
coverage, with the final link pulling in clang's profile runtime (fix with
`CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO` on `notarize_app.sh`'s xcodebuild, since
`-enableCodeCoverage` is only accepted when testing, and measure that change on its own).

Credit: the module maps, the iOS xcframework flags, the consent seam and several tests come
from PR #57 by @michael-wojcik.

# Extracting the transcription core

Status: slices 0 to 5 done and reviewed on `refactor/core-package`, and the follow-ups of the
review after the slice 5 record are in: the CI move check, the release submodule guard, the
pinned sherpa archives, the queue and retention fixes, and deviations 31 to 34.
Supersedes the framework-target approach of PR #57 (WhisperCore), whose design decisions are
reused where they still fit. Goal: one transcription core shared by the macOS app and a future
iPhone app (issue #52), with no behaviour change for the macOS app.

## Reference behaviour

"No regression" is measured against two references, because dev builds and shipped builds
differ today:

| Reference | How it is built | Used for |
|---|---|---|
| Test suite | `xcodebuild test` with `-derivedDataPath build -clonedSourcePackagesDirPath SourcePackages` (patched FluidAudio) | Every slice: the per-test pass/skip list of master (710 passed, 9 skipped on 47fe26b) must be reproduced, plus the new tests |
| Shipped app | `notarize_app.sh` (whisper, llama and ggml from `RELEASE=1 Scripts/build-native.sh` (forced, pinned and clean submodules only), `GGML_NATIVE=OFF`, so generic ggml CPU kernels, as the universal libwhisper configure it replaced in slice 2; unpatched FluidAudio) | Release smoke check before merging: load commands, embedded files, `jfk.wav` transcription identical to the current references, `docs/smoke/post-swap-<arch>.txt` since slice 2 (below) |

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
  platform set. `FORCE=1` rebuilds. Release builds pass `RELEASE=1`, which forces and first
  refuses any submodule that is uninitialised, conflicted, on another commit than HEAD pins, or
  has tracked or untracked changes; a dev build only stamps that state.
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

The slices were carried out from implementation notes kept outside the repository; what this
record needs from them is here. Inside a slice, `3.0`, `3.1` and so on number its commits in
order, and `5.5a` to `5.5d` are slice 5's move checker and its three moving commits. The gates:

- G1, Debug build: `./run.sh build`.
- G2, full hosted suite: `xcodebuild test -scheme OpenSuperWhisper` on run.sh's derived data and
  packages (`-derivedDataPath build -clonedSourcePackagesDirPath SourcePackages`),
  `-only-testing:OpenSuperWhisperTests`, with `TEST_RUNNER_OSW_TEST_GGUF` set, on the Apple
  Silicon Mac that recorded the goldens. The `Test case 'Class.test()' status` lines are extracted,
  sorted and compared with the list recorded before the slice. The one for slice 4, recorded at
  the end of slice 3, is `docs/tests/hosted-slice4.txt`, and slice 4 allowed no difference from it.
  No run may print "is implemented in both".
- G3, iOS Simulator build of the package: the autogenerated `OpenSuperWhisperCore` scheme for
  `generic/platform=iOS Simulator` with `ARCHS=arm64`, derived data in `build-ios/`, on the
  workspace's pins.
- G4, static checks: no app-only name (`AppPreferences`, AppKit, `NSAlert`, `Settings()` and the
  like) and no macOS-only availability or bare `#if arch(arm64)` in the core's sources; no
  top-level name shared by the app and the core; every app file that uses a moved symbol imports
  the core; the package pins unchanged; the FluidAudio patch still applied;
  `Localizable.xcstrings` unchanged.
- G5, the release smoke check of "Reference behaviour" on arm64 and x86_64, then `./run.sh build`.
- G6, link checks on the hosted test bundle: no exported symbol, type descriptor or ObjC class of
  the core, GRDB, FluidAudio or OSWSenseVoice, and none of the native sentinels `_whisper_full`,
  `_llama_backend_init` and `_sqlite3_open`. The app image defines the first two and only
  references `_sqlite3_open`, since GRDB uses the system SQLite (deviation 11).
- G7, an adversarial review of the slice.

Every commit passed G1, G2 and G4, and G3 once the package existed (deviation 20 covers the G2
timing of 4.5 to 4.7); G5 to G7 ran once per slice.

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
   which the unsigned builds skip. Steps, in the OpenSuperWhisper-core checkout, never the
   main one, and never with `make_release.sh`, which bumps the version, tags and pushes:
   1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./notarize_app.sh "$IDENTITY" arm64`
      (signs, notarizes and builds `OpenSuperWhisper-arm64.dmg`, which is not uploaded).
   2. Before the next architecture overwrites `build/`, which both write:
      `Scripts/smoke-release.sh build/Build/Products/Release/OpenSuperWhisper.app --expect docs/smoke/post-swap-arm64.txt`.
      It must print "smoke-release: signature valid" and "smoke-release: OK", and not the
      "not signed" note.
   3. The same two steps with `x86_64` and `post-swap-x86_64.txt`.
   4. `Scripts/build-native.sh all` to rebuild the iOS slices the release build dropped, and
      `./run.sh build` for the dev derived data that `notarize_app.sh`'s `rm -rf build` deleted.
3. `CoreConfiguration`, `TranscriptionSettings`, and the pure models and helpers.
   Done, in six code commits plus this record, each building and passing the suite, then four
   review follow-ups (deviations 13 to 15 and a tighter consent test). `DefaultsStore`, `AppIdentity`,
   `Keychain`, the `UserDefault` wrappers, `TranscriptionResult` and `TranscriptionError` moved
   first, then the custom dictionary, `AppContextProfile`, `TranscriptionPrompt`,
   `LanguageUtil`, `VoiceActivity`, `AudioPCMConverter`, `DictationModelOption` and the
   download catalogs (split out of `ModelCatalog.swift` and `Settings.swift`). `Settings` is now
   the core's `TranscriptionSettings`; the app keeps `typealias Settings` with its `init()` and
   the prompt-file statics in an extension, and both app initialisers delegate to the public
   memberwise init in the old assignment order. `AppMain.main` installs a `CoreConfiguration`
   on its first line (`AppCore.install()`), the three SwiftUI previews install it in their
   body, and `TranscriptionPostProcessing` moved with a formatter parameter. Last, every file
   that moves in slice 4 was rewired in the app, without moving: preferences, the storage root,
   the VAD model path and the history consent go through `CoreAccess`, spelled as the core's
   internal one, through a temporary app copy that reads the installed configuration and traps
   when nothing is installed. The model managers and the recording store take
   `init(storageRoot:)`, `WhisperEngine` takes its VAD path, the queue takes its settings
   factory and an async consent closure, availability checks name iOS 26 and SenseVoice code is
   behind `#if os(macOS) && arch(arm64)`.
   Measured: the suite went from 858 passed and 9 skipped to 868 passed and 9 skipped, the ten
   new tests (`ErrorBridgingTests`, `CoreConfigurationTests`, `HistoryConsentTests`,
   `StorageRootInjectionTests`) being the only difference, with the llama half of the lifecycle
   test run. The package builds for the iOS Simulator at every commit that changes sources (the
   first one only adds a test). The release smoke check
   (`build-release-unsigned.sh`, then `smoke-release.sh --expect docs/smoke/post-swap-<arch>.txt`)
   gives reports identical to the post-swap references on arm64 and on x86_64 under Rosetta,
   and the test bundle holds no symbol, type descriptor or ObjC class of the core, GRDB,
   FluidAudio or OSWSenseVoice, and no native sentinel. `Localizable.xcstrings` and the package
   pins did not change.
4. Engines, LLM cleanup, model managers and catalogs, the transcription service, recording
   storage and the queue.
   Done, in seven code commits, three review follow-ups and the records. The engines and the
   SenseVoice model manager moved first, with FluidAudio as a core dependency, then the Whisper
   and LLM model managers, LLM cleanup, the compute policy, the transcription service with the
   model catalog and `Notification.Name.modelSelectionDidChange` (the app's declaration went),
   and last recording storage, retention and the queue together, with GRDB as a core dependency
   and the temporary app copy of `CoreAccess` deleted. Nothing in the app names `CoreAccess`
   any more, and the app and the core share no top-level name. The last code commit took back
   to internal every public the move needed on the way: the engine protocol and its witnesses,
   four of the five engines, `TranscriptionError`, the audio, prompt and post-processing
   helpers, the service's progress and the slice-2 native wrappers. The public surface is the
   planned final list plus the GRDB witness of deviation 18, less the not-installed message
   (deviation 21). That list keeps a few members the app no longer calls, which the core or
   the tests use: `AppleSpeechSupport.hasInstalledModel`, `CustomDictionary.promptBoost`, the
   four flags of `TranscriptionSettings` (`isAsianLanguage`, `shouldApplyAsianAutocorrect`,
   `shouldApplyCustomDictionary`, `shouldBoostCustomDictionary`) and `enforcesLengthRatio`. They
   are left for the iPhone app to settle.
   Measured: the hosted suite reproduces `docs/tests/hosted-slice4.txt` exactly at every code
   commit (868 passed, 9 skipped, the llama half of the lifecycle test run), and the package
   builds for the iOS Simulator at every commit. The package pins did not move when FluidAudio
   and GRDB became dependencies of the local package, not even `originHash`, and
   `Localizable.xcstrings` did not change. The release smoke check gives reports identical to
   the post-swap references on arm64 and on x86_64 under Rosetta. The test bundle still holds
   no symbol, type descriptor or ObjC class of the core, GRDB, FluidAudio or OSWSenseVoice, and
   no native sentinel; the Debug image now defines 94 core type descriptors (46 after slice 3)
   and GRDB's.
5. Core test target (macOS and iOS Simulator, run with the patched FluidAudio checkout);
   tests move with a committed rename map; the total may only grow.
   Done, in four commits that add the target and 25 new tests, a checker, three moving commits, the
   CI job and this record, then four review follow-ups: the test preferences behind a lock, a
   stricter checker, the simulator picker and the CI cache and iOS step. `OpenSuperWhisperCoreTests`
   is a test target of the package, built and run only through the project's committed
   `OpenSuperWhisperCoreTests` scheme, so it uses the workspace pins and run.sh's patched
   FluidAudio. Run it after `./run.sh build` with `Scripts/test-core.sh macos|ios [xcodebuild args]`
   (derived data in `build-core/`; the iOS slices are built when missing, `OSW_SIM_DESTINATION`
   picks the simulator, otherwise the first iPhone of the newest runtime the selected Xcode's
   simulator SDK can target). Never `swift test`: it resolves on its own into `.build/` with an
   unpatched FluidAudio and writes `OpenSuperWhisperCore/Package.resolved`. Every XCTest class
   derives from `CoreTestCase`, which installs one test configuration (`CoreTestEnvironment`,
   through `replaceForTesting`) with in-memory preferences that touch no UserDefaults or Keychain, a
   per-process storage root in the temporary directory, the app's Silero file by path and `.cpuOnly`
   on the simulator. Fixtures are read in place through `#filePath` (or `OSW_FIXTURES_ROOT`), the
   0.13.3 database is the target's only resource. New tests: process isolation, the installed
   configuration and the replace semantics, the not-installed trap (Swift Testing exit tests,
   macOS), whisper under both compute policies and llama under `.cpuOnly`, the platform gates and
   the fixtures. 159 tests in 18 whole files moved from the hosted suite
   (`docs/test-moves-slice5.txt`, old id to new id), each with only the app import dropped,
   `CoreTestCase` as base class and, in `RecordingMigrationTests`, the fixture found through
   `Bundle.module`. `Scripts/check-test-moves.sh` checks the hosted and core results against
   the map, and with `--slice5` against `docs/tests/hosted-slice4.txt` too. Always checked, CI
   included: no failure, no moved test back in the hosted suite, every moved one present and passed
   on both core destinations (a skip fails). With `--slice5`, a local gate of this slice: every
   unmoved reference test still hosted, no hosted test outside the reference, at least 184 results
   in a core macOS run (the floor less the 718 unmoved reference tests) and at least 902 results in
   all; `--strict` adds equal statuses. The reference is frozen at slice 4: it records the suite
   this slice started from and is not a standing CI gate, since any later PR that adds, renames or
   removes a hosted test differs from it. Renaming a moved core test means updating its new id in
   the map. CI gained a `core-tests` job
   (macOS, then the iOS Simulator even after a macOS failure, with the native cache saved as soon as
   it is built), and the build job checks its hosted results against the map. Measured (M5 Pro,
   Xcode 27.0, `TEST_RUNNER_OSW_TEST_GGUF` set): the hosted suite has 718 results and the core 184
   on macOS (all passed) and 180 on the iOS 26.5 simulator (179 passed,
   `testAutomaticTranscriptIsExact` skipped there by design), so 902 in all. The hosted list is the
   reference minus the 159 mapped ids at every moving commit; from 5.5d on, one keyboard test of the
   hosted suite skipped for an environmental reason (deviation 29). In CI mode
   (`TEST_RUNNER_OSW_GOLDEN_MACHINE=0`, no model) the core gives 178 passed and 6 skipped on macOS
   and 174 and 6 on the iOS 27.0 simulator: the four exact whisper tests and the two llama tests
   skip, and the cpu-only whisper smoke test runs on both. On the whisper side, `.cpuOnly` with the
   VAD gives "...can do for you. Ask what you can do..." where Metal gives "...for you, ask
   what...", byte-identical on macOS (generic kernels) and on the simulator (baseline arm64 kernels)
   and stable across runs; it is pinned as `jfkTranscriptCPU`. The timestamped run, which skips the
   VAD, and the silence case match Metal, and `.automatic` gives the app's golden from the
   standalone package. On the llama side, a `.cpuOnly` context and
   `BuiltInLlamaBackend(computePolicy: .cpuOnly)` load and generate on macOS and on the simulator.
   Neither policy keeps Metal out entirely, as the ggml log shows on macOS and on the simulator:
   whisper under `.cpuOnly` logs `use gpu = 0` and `no GPU found` and creates no Metal context (no
   `ggml_metal_init`), but ggml's backend registry still runs `ggml_metal_device_init`, which
   creates the MTLDevice, when whisper first counts the devices (`devices = 3`; a run of that one
   test on its own shows it). llama under `.cpuOnly` offloads 0 of 29 layers, yet picks MTL0 as a
   model device and allocates a Metal context (`ggml_metal_init: allocating`) for every context. The
   exit tests ran natively under xcodebuild, so the documented `TrapProbe` fallback was not needed.
   The core test bundle links `@rpath/libonnxruntime.1.24.4.dylib` with the vendor rpath on macOS
   and holds one `_whisper_full`; no run printed "is implemented in both". The hosted test bundle
   still holds no symbol, type descriptor or ObjC class of the core, GRDB, FluidAudio or
   OSWSenseVoice, and no native sentinel. The release smoke check gives reports identical to the
   post-swap references on arm64 and on x86_64: the test target and the scheme are not part of the
   app. The package pins and `Localizable.xcstrings` did not change.
The extraction stops there. The iPhone app itself (issue #52) is a later project; until then
the core only has to keep building for iOS, which every slice checks. Notes for that
project: record in the foreground, transcribe on device (Parakeet, Apple Speech on iOS 26)
or remotely, exclude models from backup, and scope `make_release.sh` to the macOS target
before an iOS target joins the project.

## Deviations from this plan

Recorded as the slices land, so the plan above keeps its original wording.

1. SenseVoice engine location. `SenseVoiceEngine` and `SenseVoiceModelManager` go in the
   `OpenSuperWhisperCore` target, with the engine behind `#if os(macOS) && arch(arm64)`.
   `OSWSenseVoice` keeps sherpa and `SenseVoiceRecognizer`. The engine conforms to core types
   and `OSWSenseVoice` is a dependency of the core, so the engine cannot live there without a
   cycle.
2. Seam names. The plan's `vadModelURL` is `vadModelPath: () -> String?`, which keeps today's
   lookup expression byte-identical. The storage root is a non-optional `() -> URL`.
3. New configuration fields. `CoreConfiguration` also carries `makeSettings` (main actor) and
   `confirmEnableHistory` (main actor, `async`), because the queue moves to the core. The
   consent closure is `async` so an iPhone host can present its own UI without a public-API
   change. On macOS it wraps the same `runModal`, and the queue calls it from the main actor,
   so nothing suspends.
4. Sendable seam. `CoreConfiguration` is `Sendable` with `@Sendable` closures, and
   `CorePreferences` is `AnyObject, Sendable`. `AppPreferences` declares `@unchecked Sendable`,
   which changes nothing at run time: engines already read it from detached tasks and from the
   llama queue, and all its state is in UserDefaults and the Keychain. The public value types
   that moved (`TranscriptionSettings`, `CustomDictionaryEntry` and its `Spacing`,
   `AppContextProfile`, `DictationModelOption`, `SettingsDownloadableModel`,
   `SettingsFluidAudioModel`) declare `Sendable` explicitly: Swift infers it only for internal
   types, so without it the seam would hand out values another module cannot send.
5. Preview exemption. The core cannot build a preview configuration that reads
   `AppPreferences`. Instead of the core skipping the trap in previews, each preview calls
   `AppCore.install()`, and previews then read what they read today.
6. "Pure text cleanup steps" narrowed to TranscriptionPostProcessing, the custom dictionary and
   TranscriptionPrompt. The AppPreferences filler-word, stop-phrase and submit functions,
   `IndicatorViewModel.applyPostProcessing`, PunctuationCalibration, KeyboardLanguage and
   RecentTranscripts stay in the app until the iPhone app needs them.
7. Text formatter injection. The formatter reaches `TranscriptionPostProcessing.finish` as a
   parameter fed by the configuration, not through five engine initialisers. The configuration
   is only read when Asian autocorrect applies, as the Rust formatter was only called then.
8. Error domain. `TranscriptionError` pins its `NSError` domain to
   `"OpenSuperWhisper.TranscriptionError"`, so user-visible error text stays identical. The
   codes 0, 1 and 2 already matched without an explicit `errorCode`.
9. RecordingStore still calls the queue. The plan says the consent closure "also removes
   RecordingStore's call into the queue". `RecordingStore.deleteRecording` still calls
   `TranscriptionQueue.shared.cancelRecording`. Once both types are in the core it compiles and
   behaves as today; deleting a pending recording still creates the queue and, through it,
   `TranscriptionService.shared`. `RecordingStore(storageRoot:)` is only half injected: its
   database follows the given root, but `Recording.url` goes through the static
   `recordingsDirectory`, which reads the configured root, so `deleteRecording`,
   `deleteAllRecordings` and retention remove audio under the configured root, and the cancel
   goes to the shared queue rather than the one that owns the store. The macOS app only builds
   stores on the configured root, so nothing changes there; the iPhone host must do the same
   until `Recording` gets a root-relative URL. Fix both together before a core test or the
   iPhone host builds a store on another root.
10. The history consent test does not end on a failed recording. The queue's first pass
    (`cleanupMissingFiles`) schedules the deletion of a dropped file whose source does not
    exist. Because `RecordingStore` cancels on `TranscriptionQueue.shared` (item 9), a queue
    built with its own store still runs `processRecording` on the row, which may mark it failed
    before the delete lands; the end state is the recording gone. In the shipped app the shared
    queue owns the store, so `processRecording` returns early on the cancelled recording.
    `HistoryConsentTests` checks that the accepted file reaches the temp store as pending, that
    the queue finishes, that the temp store ends empty and that the shared store's rows did not
    change. The deletion also creates `TranscriptionQueue.shared` in the test host and points
    its audio removal at the shared recordings folder, so the test is not a full isolation of
    the store.
11. Gate wording. The static check for `Settings()` in core code also matched
    `CoreAccess.makeSettings()`, the spelling the plan asks for; the check now requires that
    `Settings()` is not part of a longer name. G6 lists `_sqlite3_open` as a sentinel present in
    the app image, but GRDB uses the system SQLite, so the app only references it; the checks on
    the test bundle are unaffected. The G2 list extraction (`tr -d '\n' | grep -o ... | sort -u`)
    can splice xcodebuild's end-of-run trailer into one result name, which happened in the run
    recorded as the slice-4 reference (`docs/tests/hosted-slice4.txt`). The trailer is now
    stripped before sorting and any line that is not a clean `Test case 'Class.test()' status`
    fails the run; the slice-4 reference was normalised that way (877 lines, 868 passed, 9
    skipped).
12. `WhisperEngine`'s convenience `init(modelPathOverride:)` is not marked `public` while the
    class is still in the app (slice 3). It becomes public when the engine moves (slice 4).
13. Trap wording. The planned `notInstalledMessage` told core tests to install a configuration
    "into a slot of their own", which never avoids the trap since `CoreAccess` reads only the
    process's slot. It now names `CoreConfiguration.replaceForTesting(_:)` and the designated
    initialisers, and the `ConfigurationSlot` comment says a private instance is for testing the
    slot itself. The `CoreConfiguration` comment (and the 3.4 commit message) said every field is
    a provider; `computePolicy` is a plain value, and the comment now says so.
14. `/build-ios/` is ignored from slice 3, in its own commit, not in 4.1: gate G3 leaves its
    derived data at the repository root after every commit. Commit 4.1 still adds the
    `OpenSuperWhisperCore/Package.resolved` and `.swiftpm/` lines.
15. `Sendable` on the public value types (item 4) is a slice-3 follow-up commit, an additive
    conformance on moved code that the plan did not list.
16. The same conformance goes on the public value types that move in slice 4, in the commit
    that moves each one: `LLMModelDescriptor` (4.2) and `LLMStatus` (4.3). The plan listed them as
    public without it. Apart from that, commits 4.1 to 4.3 made public exactly the planned final
    members and the engine protocol's witnesses (public until 4.7); the app's remaining code
    needed nothing more.
17. The compute policy (4.4) has no test of its own. Slice 4 added no test file, and the hosted
    suite had to reproduce `docs/tests/hosted-slice4.txt` exactly. On the Whisper side,
    `.automatic` is covered by the unchanged goldens, VAD pins and lifecycle test, which build
    `WhisperEngine` through the convenience init and so read the installed policy. On the llama
    side, the hosted suite never runs `BuiltInLlamaBackend.loadContextOnQueue`; its `.automatic`
    branch is the unchanged `LlamaContext(modelPath:)` call, which the lifecycle test exercises
    directly. `.cpuOnly` is first exercised by the core test target (slice 5).
18. `Recording.Columns` is public. GRDB 7's `TableRecord` declares `associatedtype Columns`, and
    the nested enum witnesses it, so the compiler refuses an internal one once `Recording` is
    public. Its column constants stay internal. The planned list of public `Recording` members
    did not name it.
19. `Sendable` (deviation 16) also goes on `RecordingStatus`, `Recording` and `RetentionUnit`,
    in the commit that moves them (4.6).
20. Gate G2 for commits 4.5 to 4.7 ran after the commits rather than before. A macOS privacy
    prompt asking whether "OpenSuperWhisper" may read the Documents folder held every hosted
    test host in its first file open, while the screen was locked, and answering it is the
    user's decision. Each commit was meanwhile built with its test bundle
    (`xcodebuild build-for-testing`, G2's arguments), and the full suite was run on each of them
    once the prompt was answered, before this record. The lists match the reference exactly.
21. `CoreConfiguration.notInstalledMessage` is internal, although the planned final list kept it
    public. The plan made it public only so the temporary app copy of `CoreAccess` could trap
    with the same text, and that copy went in 4.6. The app's `AppCore.configuration` is private
    for the same reason: only `AppCore.install()` reads it now. A review follow-up after the
    slice 4 record, together with a whitespace-only realignment of the shared queue's arguments.
22. The project references the package folder. Xcode put no test target of
    `OpenSuperWhisperCore` in its build graph while the project only had the
    `XCLocalSwiftPackageReference`, so the committed scheme resolved to nothing ("Supported
    platforms for the buildables in the current scheme is empty"). A `PBXFileReference` to the
    folder in the main group, which is what Xcode writes when a local package is dragged in,
    makes the package an editable root and exposes `OpenSuperWhisperCoreTests`. It is in no build
    phase; the app build, the pins and the autogenerated `OpenSuperWhisperCore` scheme that G3
    uses are unchanged. The committed scheme is `OpenSuperWhisperCoreTests`, a name of its own so
    that autogenerated scheme stays visible.
23. onnxruntime is linked into the core test bundle on macOS (`unsafeFlags` on the test target
    only, arm64 dylib found by an absolute rpath into `vendor/`), decided up front: the bundle
    links the core as object files and sherpa leaves `_OrtGetApiBase` undefined, which only dead
    stripping hid. The library product links nothing new.
24. No `OpenSuperWhisperCore/Package.resolved` is committed, which closes the slice-5 follow-up:
    every core build and test goes through the project, so the workspace pins are the only ones
    read, and a second file could only drift. Its `.gitignore` line stays. `test-core.sh` fails
    when a run leaves a resolution file or moves the pins. The repository root holds an old
    tracked `Package.resolved` that nothing reads, so the check accepts tracked files that are
    unchanged rather than requiring that only the workspace file exists.
25. Moved files are whole files, with three edits only: the app import dropped, `CoreTestCase`
    as base class, and `Bundle.module` for the 0.13.3 fixture in `RecordingMigrationTests`, whose
    stale comment about the synchronized group stays as it was. Candidates for a later split,
    not verified pure: `CustomDictionaryTests`, `EngineCapabilitiesTests` and
    `HebrewIvritSupportTests` (OpenSuperWhisperTests.swift), `TranscriptionErrorTests`
    (ErrorFeedbackTests.swift), `AsyncSemaphoreTests` (DictationPipelineTests.swift) and eight of
    SpeechTrimmingTests' nine tests.
26. `WhisperGoldenTests`, the VAD tests (`WhisperEngineVadTests`, `VadIntegrationTests`,
    `SpeechTrimmingTests`) and `EngineFactoryTests` stay hosted: they pin the app process (its
    configuration, the VAD model in the app bundle, the macOS build's gates). Their core
    counterparts are `CoreWhisperComputePolicyTests` and `PlatformAvailabilityTests`.
27. `BuiltInLlamaBackend.init(computePolicy:)` went from private to internal so a core test can
    build the backend on `.cpuOnly`; no public or behaviour change. This is the first exercise of
    `.cpuOnly` on the llama side (deviation 17).
28. Test-level choices. `PlatformAvailabilityTests.testSenseVoiceModelsAreListedOnlyWhereCompiled`
    stages two empty files under the SenseVoice model's names in the test storage root: the
    catalog also requires the download, so without them it would be empty on macOS too.
    `CoreTestIsolationTests` checks the defaults suite by writing a key through
    `DefaultsStore.current` and reading it back from the pid-named suite, since `UserDefaults`
    cannot report its suite name. `CoreWhisperComputePolicyTests` gets a `jfkTranscriptCPU`
    constant for the measured `.cpuOnly` string (one for both platforms, since they agree).
29. Gate G2 from 5.5d on: `KeyboardLayoutProviderTests.testResolveInfo_nonANSI_returnsNil` skipped
    where the reference has it passed, so the strict check reported that one status, twice in a
    row. The test skips when `LMGetKbdType()` reports an ANSI keyboard, and a probe outside any
    test reported exactly that at the time (the reference was recorded on the ISO internal
    keyboard); the app code and the test file are byte-identical to the slice-4 base. Every other
    check, the non-strict one included, passed. The review asked for one more hosted run after
    typing on the internal keyboard. The run after the review follow-ups still had
    `LMGetKbdType()` at 3 (ANSI) when it started, with the French internal keyboard the only one
    attached, and gave the same 718 results as before, this test skipped. A key on the internal
    keyboard has to come from the user, so the exception is accepted as it stands: the strict
    check is green but for this one status, and a hosted run after such a key press should show
    it passed again. It did: the full hosted run after the follow-ups of the next review gave
    exactly the reference minus the 159 mapped ids, this test passed, and the strict check was
    green.
30. The `core-tests` CI job still runs `./run.sh build`, a full Debug app build, where resolving
    the packages and patching FluidAudio would do. The review offered to factor the patch step out
    of run.sh; the job timeout went up to the sum of its step timeouts instead, which leaves the
    developers' entry point alone.
31. Hosts do not build core types through their initialisers yet. The initialisers that take a
    dependency (`WhisperModelManager`, `LLMModelManager` and `SenseVoiceModelManager` with
    `storageRoot:`, `RecordingStore(storageRoot:)`, the queue's, `WhisperEngine`'s and
    `BuiltInLlamaBackend(computePolicy:)`) are internal and reached by the core tests through
    `@testable import`. A host goes through `CoreConfiguration` and the `.shared` instances built
    from it, as the macOS app does. Making them public waits for the iPhone app, together with
    deviation 9, since a store on another root is not fully injected yet.
32. `AppleSpeechSupport` reads and writes three keys (`appleSpeechSupportedLanguages`,
    `appleSpeechInstalledLanguages`, `appleSpeechLocaleOverrides`) on `DefaultsStore.current`
    directly, not through `CorePreferences`, so the protocol does not list every member the core
    reads or writes. The keys and the store are the ones 0.13.3 used, so nothing changes for the
    macOS app, but an iPhone host cannot redirect them, and in the core tests they go to the
    per-process defaults suite rather than the in-memory test preferences.
33. The compute policy is fixed per process. It is a plain value of the configuration a host
    installs once, the shared llama backend keeps the one it was built with, and `WhisperEngine`
    reads it when it is built, so a host cannot run on Metal in the foreground and on the CPU only
    in the background. The plan's `.cpuOnly` "for iPhone background work" needs a policy read per
    load (or passed per call) first; the `ComputePolicy` comment now says so.
34. `SenseVoiceModelManager` is public and compiled on iOS, where no SenseVoice engine exists, so
    an iPhone host could download a model nothing loads. Putting it behind the engine's
    `#if os(macOS) && arch(arm64)` would break the Intel app, whose onboarding names it outside any
    `#if` (the SenseVoice choice is hidden at run time there), and `os(macOS)` alone would change a
    moved test file (`StorageRootInjectionTests`) and two core tests. Left as it is for the iPhone
    app to settle.

## Follow-ups kept out of the extraction

Each is a behaviour change and gets its own PR with a test: the FluidAudio boost path loading a second model set per call; FluidAudio `versionOverride`
ignored when boosting (`FluidAudioEngine` L130, L154); `applyOneOffModel` writing persisted
preferences; the main-window recorder bypassing `DictationPipeline`; shipping the FluidAudio
patch in releases (ideally via a fork tag); native ARM kernels in releases; integrity checks
on model downloads; API keys sent over plain http; the remote local-fallback factory
(`fallbackEngineChoice`) handing an option's identifier to Whisper as a model path for
SenseVoice on Intel (`"default"`) and for any engine it does not know (`"remote"` included),
and building the selected Whisper model for `"apple"` below macOS 26.

Also out of scope, found while extracting: file-name-based model paths for iOS; `.cpuOnly`
without Metal, before the iPhone app relies on it in the background (measured in slice 5:
whisper creates no Metal context but ggml's registry creates the MTLDevice, and llama also
allocates a Metal context per context with no layer offloaded). llama should limit the model
and the context to the CPU device (`devices` in the model params) and set `op_offload = false`;
for both, ggml should not initialise the Metal device in that mode, and a core test should then
assert through the ggml log that neither `ggml_metal_device_init` nor `ggml_metal_init` appears;
the download-catalog strings in `Localizable.xcstrings`, rendered verbatim today so their
translations are unused; the `RecordingStore` to `TranscriptionQueue` call together with
`Recording.url` reading the configured root (deviation 9), then public injecting initialisers
(deviation 31); `AppleSpeechSupport`'s three keys through `CorePreferences` (deviation 32); a
compute policy that can change between loads, so background work alone runs on the CPU
(deviation 33); and `SenseVoiceModelManager` kept out of iOS builds (deviation 34). Closed in
slice 5: the iOS Simulator package build in CI (the `core-tests` job builds and tests the core
there) and the question of a committed `OpenSuperWhisperCore/Package.resolved` (deviation 24).

Release builds used to be instrumented for code coverage (Xcode enables it for the scheme),
so every CLI run wrote a `default.profraw` into the caller's directory. PR #170 makes the fix
for master and is still open; this branch carries the same change: `notarize_app.sh` and
`Scripts/build-release-unsigned.sh` pass `CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO`.
`smoke-release.sh` still points `LLVM_PROFILE_FILE` at its temp directory, which costs nothing
and covers an instrumented build.

Credit: the module maps, the iOS xcframework flags, the consent seam and several tests come
from PR #57 by @michael-wojcik.

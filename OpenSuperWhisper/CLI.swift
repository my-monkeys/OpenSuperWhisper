import AppKit
import Foundation

/// Headless command-line transcription (#150). Reached from the app's entry point when the first
/// argument is `transcribe`, so it reuses the exact same engines as the GUI without a second target.
///
///   OpenSuperWhisper transcribe <audio-file> [--json] [--model <ggml-file>] [--raw] [--language <code>]
///
/// Uses whatever engine/model is configured in the app, unless `--model` names a Whisper model.
/// Prints the transcription to stdout (plain text, or a JSON object with `--json`) and exits — no
/// dock icon, no menu bar, no windows.
enum CLI {
    static let usage = """
    OpenSuperWhisper — command-line transcription

    Usage:
      OpenSuperWhisper transcribe <audio-file> [--json] [options]
      OpenSuperWhisper bench <dir-of-wavs> [options]

    Options:
      --json             Print a JSON object ({ "file", "text" }) instead of plain text.
      --model <file>     Transcribe with Whisper on this ggml model file, whatever engine the
                         app is set to.
      --raw              Ignore the prompt file, the custom dictionary and the transcription
                         settings made in the app: a fresh install's defaults, in English
                         unless --language says otherwise.
      --language <code>  Transcribe in this language (en, fr, auto, ...).
      -h, --help         Show this help.

    `bench` loads the configured model once and transcribes every .wav in the directory, printing a
    JSON array of { "file", "ms" (transcription time), "text" } — used to benchmark engines.

    Both use the engine and settings configured in the app unless --model or --raw say otherwise.
    Set up a model in the app first.
    """

    /// A `transcribe` or `bench` command line.
    struct Invocation: Equatable {
        enum Mode: String {
            case transcribe, bench
        }

        var mode: Mode
        var target: String
        var json = false
        var modelPath: String?
        var raw = false
        var language: String?
    }

    /// Nil when the arguments are not a usable `transcribe` or `bench` call, including an option
    /// that is missing its value. Words it does not know are ignored, as they always were.
    static func parseInvocation(_ args: [String]) -> Invocation? {
        guard args.count >= 3, let mode = Invocation.Mode(rawValue: args[1]) else { return nil }
        var invocation = Invocation(mode: mode, target: args[2])
        var options = args.dropFirst(3).makeIterator()
        while let option = options.next() {
            switch option {
            case "--json":
                invocation.json = true
            case "--raw":
                invocation.raw = true
            case "--model":
                guard let path = options.next(), !path.hasPrefix("-") else { return nil }
                invocation.modelPath = path
            case "--language":
                guard let code = options.next(), !code.hasPrefix("-") else { return nil }
                invocation.language = code
            default:
                continue
            }
        }
        return invocation
    }

    /// The app's default transcription language, which `--raw` uses unless told otherwise.
    static let rawLanguage = "en"

    /// What the engine is told. With `--raw`, nothing the user has set up can reach it, so a
    /// release can be checked against a recorded transcript whatever the Mac's settings.
    static func settings(for invocation: Invocation) -> Settings {
        var settings = invocation.raw ? Settings(freshInstallLanguage: rawLanguage) : Settings()
        if let language = invocation.language {
            settings.selectedLanguage = language
        }
        return settings
    }

    /// Returns true if these arguments are a CLI invocation (and the GUI should not launch).
    static func shouldHandle(_ args: [String]) -> Bool {
        guard args.count >= 2 else { return false }
        return (["transcribe", "bench", "agent-hook", "--help", "-h"] + debugModes).contains(args[1])
    }

    /// The Liquid Glass probes (screenshots, synthetic clicks, the user's real indicator): Debug
    /// builds only, so a release binary never takes them.
    #if DEBUG && canImport(FoundationModels)
    private static let debugModes = ["gallery", "gallery-live", "indicator-live"]
    #else
    private static let debugModes: [String] = []
    #endif

    static func run(_ args: [String]) -> Never {
        if args.count >= 2, args[1] == "--help" || args[1] == "-h" {
            print(usage); exit(0)
        }
        let mode = args[1]
        // Run by the Claude Code plugin on every hook, so it answers before anything heavier.
        if mode == "agent-hook" { AgentHookCommand.run(args) }
        #if DEBUG && canImport(FoundationModels)
        if mode == "gallery" {
            MainActor.assumeIsolated {
                BubbleGallery.run(outputDir: args.count >= 3 ? args[2] : "/tmp/jev-glass/gallery")
            }
        }
        if mode == "indicator-live" {
            MainActor.assumeIsolated {
                IndicatorProbe.run(outDir: args.count >= 3 ? args[2] : "/tmp/jev-glass/indicator")
            }
        }
        if mode == "gallery-live" {
            // The probe runs its own NSApplication event loop, so this never returns on its own.
            let seconds = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
            MainActor.assumeIsolated {
                if #available(macOS 26.0, *) {
                    BubbleProbe.run(seconds: seconds)
                } else {
                    FileHandle.standardError.write(Data("gallery-live needs macOS 26+\n".utf8))
                    exit(1)
                }
            }
        }
        #endif
        guard let invocation = parseInvocation(args) else {
            fail(usage, code: 2)
        }
        let target = URL(fileURLWithPath: (invocation.target as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            fail("error: not found: \(target.path)")
        }
        let model = invocation.modelPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let model, !FileManager.default.fileExists(atPath: model.path) {
            fail("error: not found: \(model.path)")
        }

        // The engines + FluidAudio's logger print to stdout. Keep stdout clean & pipeable by
        // redirecting it to stderr, and writing only the final result to the real stdout.
        let realStdout = dup(STDOUT_FILENO)
        resultOut = FileHandle(fileDescriptor: realStdout, closeOnDealloc: false)
        dup2(STDERR_FILENO, STDOUT_FILENO)

        // No dock icon / activation for a CLI run.
        NSApplication.shared.setActivationPolicy(.prohibited)

        Task { @MainActor in
            let transcribe: (URL) async throws -> String
            if let model {
                let engine = await loadWhisper(model: model)
                transcribe = { try await engine.transcribeAudio(url: $0, settings: settings(for: invocation)) }
            } else {
                let service = TranscriptionService.shared
                // Wait for the configured engine to finish loading (model load can take a moment).
                var waited = 0.0
                while service.isLoading && waited < 120 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 0.1
                }
                if let engineError = service.engineError {
                    fail("error: \(engineError)\n(set up a model in the app first)")
                }
                transcribe = { try await service.transcribeAudio(url: $0, settings: settings(for: invocation)) }
            }
            if invocation.mode == .transcribe {
                do {
                    let text = try await transcribe(target)
                    emit(text, file: target.path, json: invocation.json)
                    exit(0)
                } catch {
                    fail("error: \(error.localizedDescription)")
                }
            } else {
                await runBench(dir: target, transcribe: transcribe)
                exit(0)
            }
        }
        // Keep the process alive on the main dispatch queue (where the @MainActor task runs) until
        // the task calls exit(). dispatchMain() never returns, satisfying the -> Never contract.
        dispatchMain()
    }

    /// `--model`: a Whisper engine on that file, built here because TranscriptionService only
    /// builds the engine the app is set to. It stays loaded until the process exits.
    @MainActor
    private static func loadWhisper(model: URL) async -> WhisperEngine {
        let engine = WhisperEngine(modelPathOverride: model.path)
        do {
            try await engine.initialize()
        } catch {
            fail("error: cannot load the Whisper model \(model.path)")
        }
        return engine
    }

    /// Transcribe every .wav in `dir` with the already-loaded engine, timing each transcription.
    /// Prints a JSON array of { file, ms, text } — the model is loaded once, so timings reflect
    /// steady-state transcription speed (not per-run model load).
    @MainActor
    private static func runBench(dir: URL, transcribe: (URL) async throws -> String) async {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var results: [[String: Any]] = []
        for file in files {
            let start = CFAbsoluteTimeGetCurrent()
            let text = (try? await transcribe(file)) ?? ""
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            results.append([
                "file": file.lastPathComponent, "ms": ms,
                "text": text.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
        resultOut.write(data)
        resultOut.write(Data("\n".utf8))
    }

    /// The real stdout (engine/library logs are redirected away from it during a run).
    private static var resultOut = FileHandle.standardOutput

    private static func emit(_ text: String, file: String, json: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let out: Data
        if json {
            out = (try? JSONSerialization.data(
                withJSONObject: ["file": file, "text": trimmed],
                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        } else {
            out = Data(trimmed.utf8)
        }
        resultOut.write(out)
        resultOut.write(Data("\n".utf8))
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(code)
    }
}

extension Settings {
    /// A fresh install's transcription settings with every prompt source empty, for `--raw`.
    /// Each field is set here rather than starting from `Settings()`, so neither the preferences
    /// nor the prompt file are read.
    init(freshInstallLanguage language: String) {
        self.selectedLanguage = language
        self.translateToEnglish = false
        self.suppressBlankAudio = true
        self.showTimestamps = false
        self.temperature = 0
        self.noSpeechThreshold = 0.6
        self.initialPrompt = ""
        self.useBeamSearch = false
        self.beamSize = 5
        self.useAsianAutocorrect = true
        self.customDictionaryEnabled = false
        self.customDictionaryBoostEnabled = false
        self.customDictionaryEntries = []
        self.useSurroundingTextAsContext = false
        self.focusedText = nil
    }
}

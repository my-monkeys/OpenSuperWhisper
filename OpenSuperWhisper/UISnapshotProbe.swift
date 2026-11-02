#if DEBUG
import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// Debug-only renderer for the redesigned screens: `OpenSuperWhisper ui-snapshot <dir> [names…]`
/// draws each screen off-screen, in light and dark, and writes PNGs. It lets the windows be
/// checked against the design without opening a second copy of the app next to the user's own.
///
/// It refuses to run outside the test isolation (`XCTestConfigurationFilePath` set), so it only
/// ever sees a throwaway preferences suite and storage folder, never the user's real ones.
@MainActor
enum UISnapshotProbe {
    static let screens: [String: () -> AnyView] = [
        "home": { AnyView(AppShellView(page: .home)) },
        "home-large-text": { AppPreferences.shared.textScale = TextScale.maximum; return AnyView(AppShellView(page: .home)) },
        "dictionary": { seedDictionary(); return AnyView(AppShellView(page: .dictionary)) },
        "dictionary-editor": { seedDictionary(openEditor: true); return AnyView(AppShellView(page: .dictionary)) },
        "snippets": { seedSnippets(); return AnyView(AppShellView(page: .snippets)) },
        "snippets-empty": { seedSnippets(empty: true); return AnyView(AppShellView(page: .snippets)) },
        "snippets-editor": { seedSnippets(openEditor: true); return AnyView(AppShellView(page: .snippets)) },
        "snippets-editor-new": {
            seedSnippets(empty: true, starting: "my email")
            return AnyView(AppShellView(page: .snippets))
        },
        "snippets-large-text": {
            seedSnippets()
            AppPreferences.shared.textScale = TextScale.maximum
            return AnyView(AppShellView(page: .snippets))
        },
        "snippets-editor-large-text": {
            seedSnippets(openEditor: true)
            AppPreferences.shared.textScale = TextScale.maximum
            return AnyView(AppShellView(page: .snippets))
        },
        "dictionary-suggested": { seedSuggestions(); return AnyView(AppShellView(page: .dictionary)) },
        "dictionary-needs-accessibility": {
            seedSuggestions()
            DictionaryOptionsGroup.snapshotDeniesAccessibility = true
            return AnyView(AppShellView(page: .dictionary))
        },
        "dictionary-suggestion-notice": { suggestionNotice() },
        "dictionary-suggestion-notice-large-text": { suggestionNotice(textScale: TextScale.maximum) },
        "style": { seedStyle(); return AnyView(AppShellView(page: .style)) },
        "style-expanded": { seedStyle(expandFirst: true); return AnyView(AppShellView(page: .style)) },
        "settings-models-remote": {
            let prefs = AppPreferences.shared
            prefs.selectedEngine = "remote"
            prefs.remoteServerURL = "https://api.groq.com/openai/v1"
            prefs.remoteServerModel = "whisper-large-v3-turbo"
            prefs.cachedRemoteModels = ["whisper-large-v3", "whisper-large-v3-turbo", "distil-whisper-large-v3-en"]
            ModelSelectionStore.shared.refresh()
            return AnyView(AppShellView(page: .home, settings: .models))
        },
        "help": { AppNavigation.shared.helpOpen = true; return AnyView(AppShellView(page: .home)) },
        "feedback-form": { feedbackCard() },
        "feedback-form-bug": { feedbackCard(stagedBug: true) },
        "feedback-form-bug-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return feedbackCard(stagedBug: true)
        },
        "feedback-form-too-long": { feedbackCard(message: String(repeating: "Log line: dictation stopped. ", count: 140)) },
        "feedback-sent": { feedbackCard(status: .sent) },
        "feedback-asked": { feedbackCard(asked: true) },
        "feedback-asked-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return feedbackCard(asked: true)
        },
        "mic-picker": { microphonePicker(.speaking) },
        "mic-picker-low": { microphonePicker(.murmuring) },
        "mic-picker-quiet": { microphonePicker(.tooQuiet) },
        "mic-picker-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return microphonePicker(.tooQuiet)
        },
        "settings-dictation-level": { microphoneSettings(.speaking) },
        "settings-dictation-level-low": { microphoneSettings(.murmuring) },
        "settings-dictation-level-quiet": { microphoneSettings(.tooQuiet) },
        "settings-dictation-level-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            // Lower than the others: at this size the quiet band falls below the fold.
            return microphoneSettings(.tooQuiet, scrolledTo: "Input volume")
        },
        "mic-picker-fixed-volume": { microphonePicker(.speaking, volume: .fixed) },
        "mic-picker-fixed-volume-quiet": { microphonePicker(.tooQuiet, volume: .fixed) },
        "settings-dictation-fixed-volume": { microphoneSettings(.tooQuiet, volume: .fixed) },
        "onboarding": { AnyView(OnboardingView().environmentObject(AppState())) },
        "onboarding-2": { AnyView(OnboardingView(initialStep: .model).environmentObject(AppState())) },
        "onboarding-3": { AnyView(OnboardingView(initialStep: .permissions).environmentObject(AppState())) },
        "onboarding-4": { AnyView(OnboardingView(initialStep: .firstTry).environmentObject(AppState())) },
        "settings-textAndAI-ai": {
            AppPreferences.shared.aiPostProcessingEnabled = true
            return scrolled(.textAndAI, to: "Format with AI")
        },
        "settings-textAndAI-prompts": {
            AppPreferences.shared.aiPostProcessingEnabled = true
            AppPreferences.shared.aiBackend = "builtin"
            return scrolled(.textAndAI, to: "Opening instruction")
        },
        "settings-textAndAI-server": {
            AppPreferences.shared.aiPostProcessingEnabled = true
            AppPreferences.shared.aiBackend = "remote"
            return scrolled(.textAndAI, to: "Server")
        },
        "settings-textAndAI-server-failed": {
            AppPreferences.shared.aiPostProcessingEnabled = true
            AppPreferences.shared.aiBackend = "remote"
            AppPreferences.shared.aiRemoteEndpoint = "https://openrouter.ai/api/v1"
            AppPreferences.shared.aiRemoteModel = "google/gemini-2.5-flash-lite"
            AppPreferences.shared.aiRemoteAPIKey = "sk-or-v1-0000demo-a1b2"
            CleanupSessionStatus.shared.record(CleanupOutcome(
                text: "", status: .failed(model: "google/gemini-2.5-flash-lite", reason: "401 Invalid API key")),
                at: Date().addingTimeInterval(-120))
            return scrolled(.textAndAI, to: "Server")
        },
        "settings-textAndAI-insertion": { scrolled(.textAndAI, to: "Warn when no field is focused") },
        "settings-privacy-context": {
            AppPreferences.shared.customDictionaryEnabled = true
            AppPreferences.shared.suggestDictionaryWords = true
            return scrolled(.privacy, to: "Suggest words from your corrections")
        },
        "settings-appearance-list": { scrolled(.appearance, to: "Order and display") },
        "settings-appearance-notch": { scrolled(.appearance, to: "Notch opening width") },
        "agent-panel": { AgentPanelSnapshot.make(focused: true) },
        "agent-panel-large-text": { AgentPanelSnapshot.make(focused: true, textScale: TextScale.maximum) },
        "agent-panel-selection": { AgentPanelSnapshot.make(selecting: true) },
        "agent-panel-draft": { AgentPanelSnapshot.make(draft: "Yes, open it and ask for a review.") },
        "agent-panel-permission": { AgentPanelSnapshot.make(showing: .permission) },
        "agent-panel-question": { AgentPanelSnapshot.make(showing: .question) },
        "agent-panel-live": {
            AgentPanelSnapshot.make(liveText: (AgentPanelSnapshot.liveConfirmed, AgentPanelSnapshot.liveVolatile))
        },
        "agent-panel-live-short": { AgentPanelSnapshot.make(liveText: ("", "Yes, open it")) },
        "agent-panel-live-large-text": {
            AgentPanelSnapshot.make(liveText: (AgentPanelSnapshot.liveConfirmed, AgentPanelSnapshot.liveVolatile),
                                    textScale: TextScale.maximum)
        },
    ]

    /// Levels staged in each of the bar's zones: green, orange, and red with the warning.
    private enum StagedLevel {
        case speaking, murmuring, tooQuiet

        var reading: InputLevelReading {
            switch self {
            case .speaking: return InputLevelReading(levelDBFS: -24, peakDBFS: -19, verdict: .normal)
            case .murmuring: return InputLevelReading(levelDBFS: -44, peakDBFS: -39, verdict: .normal)
            case .tooQuiet: return InputLevelReading(levelDBFS: -57, peakDBFS: -53, verdict: .tooQuiet)
            }
        }
    }

    /// The built-in microphone's own volume as found on the Mac that prompted the slider, or one
    /// macOS keeps to itself, as on many USB microphones.
    private enum StagedVolume {
        case settable, fixed
    }

    /// The Home microphone popover, drawn as a card over Home: an off-screen window cannot show a
    /// real popover. Levels and volumes are staged, so no microphone is opened or changed.
    private static func microphonePicker(_ level: StagedLevel, volume: StagedVolume = .settable) -> AnyView {
        seedMicrophones(level, volume: volume)
        let card = MicrophonePickerList(microphoneService: MicrophoneService.shared)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            // A real popover inherits the window's text size; this card sits outside the shell.
            .environment(\.appTextScale, AppPreferences.shared.textScale)
        return AnyView(AppShellView(page: .home).overlay(alignment: .topTrailing) {
            card.padding(.top, 150).padding(.trailing, 60)
        })
    }

    private static func microphoneSettings(_ level: StagedLevel, volume: StagedVolume = .settable,
                                           scrolledTo row: String = "Microphone") -> AnyView {
        seedMicrophones(level, volume: volume)
        return scrolled(.dictation, to: row)
    }

    /// Two made-up microphones, set directly so nothing is saved to preferences.
    private static func seedMicrophones(_ level: StagedLevel, volume: StagedVolume) {
        let builtIn = MicrophoneService.AudioDevice(id: "probe-built-in", name: "MacBook Pro Microphone",
                                                    manufacturer: "Apple Inc.", isBuiltIn: true)
        let usb = MicrophoneService.AudioDevice(id: "probe-usb", name: "Shure MV7",
                                                manufacturer: "Shure", isBuiltIn: false)
        let service = MicrophoneService.shared
        service.availableMicrophones = [builtIn, usb]
        service.selectedMicrophone = builtIn
        service.currentMicrophone = builtIn
        InputLevelMonitor.shared.stage(level.reading)
        switch volume {
        case .settable: InputVolumeModel.shared.stage(volume: 0.38, isSettable: true)
        case .fixed: InputVolumeModel.shared.stage(volume: nil, isSettable: false)
        }
    }

    /// A rubric with Advanced on, scrolled to one of its rows, for the parts below the fold.
    private static func scrolled(_ rubric: SettingsRubric, to row: String) -> AnyView {
        AdvancedRubrics.shared.set(rubric.rawValue, true)
        let view = AnyView(AppShellView(page: .home, settings: rubric))
        AppNavigation.shared.settingsFocusRow = row
        return view
    }

    /// Home with the Feedback card open on a staged draft. Its sender fails without a request
    /// ever being made: the endpoint notifies the owner, and a snapshot is never meant to.
    private static func feedbackCard(stagedBug: Bool = false, message: String? = nil,
                                     status: FeedbackFormModel.Status = .editing,
                                     asked: Bool = false) -> AnyView {
        let model = FeedbackFormModel(sender: FeedbackSender(transport: { _ in throw URLError(.cancelled) }),
                                      onSent: {})
        if let message {
            model.kind = .bug
            model.message = message
        }
        if stagedBug {
            model.kind = .bug
            model.message = "The bubble stays on screen after I stop dictating in Mail. It goes away once I click elsewhere."
            model.email = "camille@example.com"
        }
        model.stageStatus(status)
        if asked {
            AppNavigation.shared.askForFeedback()
        } else {
            AppNavigation.shared.openFeedback()
        }
        return AnyView(AppShellView(page: .home, feedback: model))
    }

    static func run(outputDir: String, names: [String]) -> Never {
        guard DefaultsStore.isRunningTests else {
            FileHandle.standardError.write(Data("ui-snapshot: set XCTestConfigurationFilePath=/dev/null so it runs isolated\n".utf8))
            exit(2)
        }
        let dir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppPreferences.shared.hasCompletedOnboarding = true
        // OSW_SNAPSHOT_DEMO=1: a ready app on Parakeet v3, for the README's screenshots.
        if ProcessInfo.processInfo.environment["OSW_SNAPSHOT_DEMO"] != nil {
            PermissionsManager.snapshotGrantsAll = true
            AppPreferences.shared.selectedEngine = "fluidaudio"
            AppPreferences.shared.fluidAudioModelVersion = "v3"
            var triggers = RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers)
            triggers.triggers = [.modifier(.rightOption)]
            AppPreferences.shared.recordingTriggers = triggers.json
            ModelSelectionStore.shared.refresh()
        }
        seedRecordings()

        var all = screens.merging(onboardingScreens) { current, _ in current }
            .merging(reportScreens) { current, _ in current }
        for rubric in SettingsRubric.allCases {
            all["settings-\(rubric.rawValue)"] = {
                AdvancedRubrics.shared.set(rubric.rawValue, false)
                return AnyView(AppShellView(page: .home, settings: rubric))
            }
            all["settings-\(rubric.rawValue)-advanced"] = {
                AdvancedRubrics.shared.set(rubric.rawValue, true)
                return AnyView(AppShellView(page: .home, settings: rubric))
            }
        }
        let wanted = names.isEmpty ? all.keys.sorted() : names
        let size = CGSize(width: Double(ProcessInfo.processInfo.environment["OSW_SNAPSHOT_WIDTH"] ?? "") ?? 1080,
                          height: Double(ProcessInfo.processInfo.environment["OSW_SNAPSHOT_HEIGHT"] ?? "") ?? 760)
        for name in wanted {
            guard let make = all[name] else {
                print("ui-snapshot: unknown screen \(name)")
                continue
            }
            for dark in [false, true] {
                AppNavigation.shared.helpOpen = false
                AppNavigation.shared.feedbackOpen = false
                resetReportStaging()
                // A large-text screen would otherwise leave every later screen of the run large.
                AppPreferences.shared.textScale = TextScale.default
                let view = make()
                let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                render(view, size: size, dark: dark, to: file)
                print("ui-snapshot: \(file.path)")
            }
        }
        exit(0)
    }

    private static func render(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) {
        let locale = Locale(identifier: ProcessInfo.processInfo.environment["OSW_SNAPSHOT_LOCALE"] ?? "en")
        let host = NSHostingView(rootView: view
            .environment(\.appTextScale, TextScale.default)
            .environment(\.locale, locale))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        // OSW_SNAPSHOT_SCALE=2 draws at Retina density, whatever screen this runs on.
        let scale = Double(ProcessInfo.processInfo.environment["OSW_SNAPSHOT_SCALE"] ?? "") ?? 0
        let rep: NSBitmapImageRep
        if scale > 0, let custom = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            custom.size = size
            rep = custom
        } else {
            guard let cached = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            rep = cached
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    /// A few made-up dictations so Home has something to show.
    private static func seedRecordings() {
        let now = Date()
        let samples: [(TimeInterval, String, String?, String?, RecordingStatus, String?)] = [
            (-60 * 18, "I'll send you the mockups tomorrow morning. Thanks for the feedback, shall we meet on Thursday?", "Mail", "Parakeet v3", .completed, nil),
            (-60 * 29, "Add a search field and a button to clear the input in the history view.", "Claude Code", "Parakeet v3", .completed, nil),
            (-60 * 62, "product-meeting-0910.m4a", nil, "Whisper large-v3-turbo", .completed, "/tmp/product-meeting-0910.m4a"),
            (-60 * 90, "Failed to transcribe: the audio file is empty", nil, "Parakeet v3", .failed, nil),
            (-86_400 - 3_600, "An idea for this weekend: turn my reading notes into index cards.", "Notes", "Parakeet v3", .completed, nil),
        ]
        // What the engine wrote before the cleanup, for the first one: the history offers it back.
        let originals = [0: "i'll send you the mock ups tomorrow morning thanks for the feedback shall we meet on thursday"]
        // The first was cleaned up; the second hit a refused key and kept the engine's text.
        let cleanups: [Int: (String, String?)] = [0: ("google/gemini-2.5-flash-lite", nil),
                                                   1: ("google/gemini-2.5-flash-lite", "401 Invalid API key")]
        for (index, (offset, text, app, model, status, source)) in samples.enumerated() {
            let recording = Recording(id: UUID(), timestamp: now.addingTimeInterval(offset),
                                      fileName: "\(Int(now.timeIntervalSince1970 + offset)).wav",
                                      transcription: text, duration: 6, status: status, progress: 1,
                                      sourceFileURL: source, sourceAppName: app, modelUsed: model,
                                      rawTranscription: originals[index] ?? (source == nil ? text : nil),
                                      cleanupModel: cleanups[index]?.0, cleanupError: cleanups[index]?.1)
            RecordingStore.shared.addRecording(recording)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
}
#endif

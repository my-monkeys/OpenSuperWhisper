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
        "style": { seedStyle(); return AnyView(AppShellView(page: .style)) },
        "style-expanded": { seedStyle(expandFirst: true); return AnyView(AppShellView(page: .style)) },
        "help": { AppNavigation.shared.helpOpen = true; return AnyView(AppShellView(page: .home)) },
        "onboarding": { AnyView(OnboardingView().environmentObject(AppState())) },
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
        "settings-textAndAI-insertion": { scrolled(.textAndAI, to: "Warn when no field is focused") },
        "settings-appearance-list": { scrolled(.appearance, to: "Order and display") },
        "settings-appearance-notch": { scrolled(.appearance, to: "Notch opening width") },
    ]

    /// A rubric with Advanced on, scrolled to one of its rows, for the parts below the fold.
    private static func scrolled(_ rubric: SettingsRubric, to row: String) -> AnyView {
        AdvancedRubrics.shared.set(rubric.rawValue, true)
        let view = AnyView(AppShellView(page: .home, settings: rubric))
        AppNavigation.shared.settingsFocusRow = row
        return view
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
        seedRecordings()

        var all = screens
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
                let view = make()
                let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                render(view, size: size, dark: dark, to: file)
                print("ui-snapshot: \(file.path)")
            }
        }
        exit(0)
    }

    private static func render(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.appTextScale, TextScale.default))
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
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
        for (offset, text, app, model, status, source) in samples {
            let recording = Recording(id: UUID(), timestamp: now.addingTimeInterval(offset),
                                      fileName: "\(Int(now.timeIntervalSince1970 + offset)).wav",
                                      transcription: text, duration: 6, status: status, progress: 1,
                                      sourceFileURL: source, sourceAppName: app, modelUsed: model)
            RecordingStore.shared.addRecording(recording)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
}
#endif

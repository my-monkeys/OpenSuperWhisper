import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// Every control in the Settings window has to sit inside the window, in every shipped language.
///
/// #138: one segmented control, 606pt wide at the default window, pushed the whole content out on
/// both sides, sidebar included. Nothing failed and nothing was logged; only a screenshot showed
/// it. This renders the real `SettingsView` in an off-screen window and fails on either of two
/// signals. Any view whose frame leaves the window: every view rather than only `NSControl`s,
/// because on recent macOS the menus and buttons SwiftUI draws itself are not controls, though
/// each still has a focus-ring view the size of what it draws. And any row `SPaneStack` had to lay
/// out wider than its pane, which is the only way to see text SwiftUI draws with no view at all.
///
/// Not covered: the Models > Remote fallback-model picker, which needs a downloaded model with a
/// long name, and whatever opens in a window of its own (the dictionary rule popover, the
/// punctuation calibration sheet).
///
/// Set `OSW_LAYOUT_SNAPSHOTS` to a directory (through `TEST_RUNNER_OSW_LAYOUT_SNAPSHOTS` with
/// xcodebuild) to also get a PNG of every render.
@MainActor
final class SettingsLayoutTests: XCTestCase {

    private static let languages = ["en", "de", "es", "fr", "it", "pt-BR", "vi"]
    private static let defaultSize = CGSize(width: 780, height: 600)
    /// The root view's own minimum; the window cannot be made narrower than this.
    private static let minimumSize = CGSize(width: 720, height: 540)

    /// Names with no length limit, long enough that only a cap keeps their row inside the pane.
    private static let longName = String(repeating: "Home LiteLLM behind the office VPN ", count: 5)
    private static let longModelID = "organisation/" + String(repeating: "very-long-model-name-", count: 8) + "q4"
    private static let ruleBundleID = "com.example.settings-layout-test"

    private var realMicrophones: [MicrophoneService.AudioDevice] = []
    private var realSelection: MicrophoneService.AudioDevice?

    private let preset = RemoteUserPreset(id: UUID(), name: longName,
                                          serverURL: "https://layout-test.invalid/v1",
                                          model: "layout-test-model",
                                          timeoutEnabled: false, timeoutSeconds: 30)

    override func setUp() async throws {
        // Preferences live in a suite private to this test process (DefaultsStore), so nothing
        // here reaches the user's settings. Both cleanup switches on, so the Output pane shows
        // its widest section and the Rules pane its formatting one; the rest seeds the rows
        // whose width comes from data rather than from a label.
        let prefs = AppPreferences.shared
        prefs.aiPostProcessingEnabled = true
        prefs.appContextFormattingEnabled = true
        prefs.retentionMaxCountEnabled = true
        // The test host is the app, and its RecordingStore is the user's real database. With the
        // limit switched on, the row renders; at the stepper's ceiling, no retention pass that
        // runs meanwhile could ever delete a recording.
        prefs.retentionMaxCount = 100_000
        prefs.textScale = TextScale.default
        prefs.customDictionaryEnabled = true
        prefs.customDictionaryEntries = [
            CustomDictionaryEntry(original: "sign off", replacement: Self.longName)
        ]
        // Two models, whatever this machine has downloaded, so the Rules pane shows its
        // per-app model section and the seeded rule below.
        prefs.cachedRemoteModels = [Self.longModelID, "layout-test-model-2"]
        realMicrophones = MicrophoneService.shared.availableMicrophones
        MicrophoneService.shared.availableMicrophones.append(
            MicrophoneService.AudioDevice(id: "layout-test-microphone", name: Self.longName,
                                          manufacturer: nil, isBuiltIn: false))
        // Pinned but unplugged: the picker lists it as "(not connected)" and the hint names the
        // input used meanwhile, both of which add width to the row. Set directly, so nothing is
        // saved to preferences.
        realSelection = MicrophoneService.shared.selectedMicrophone
        MicrophoneService.shared.selectedMicrophone = MicrophoneService.AudioDevice(
            id: "layout-test-unplugged", name: Self.longName, manufacturer: nil, isBuiltIn: false)
        RemoteUserPresets.add(preset, apiKey: nil)
        prefs.remoteServerURL = preset.serverURL
        prefs.remoteServerModel = preset.model
        AppContextModelRules.set(
            DictationModelOption(engine: "remote", identifier: Self.longModelID,
                                 displayName: Self.longModelID),
            for: Self.ruleBundleID)
    }

    override func tearDown() async throws {
        // Other test classes share this process and its preferences.
        RemoteUserPresets.remove(preset.id)
        AppContextModelRules.remove(bundleID: Self.ruleBundleID)
        MicrophoneService.shared.availableMicrophones = realMicrophones
        MicrophoneService.shared.selectedMicrophone = realSelection
        for key in ["aiPostProcessingEnabled", "appContextFormattingEnabled", "retentionMaxCountEnabled",
                    "retentionMaxCount", "textScale", "remoteServerURL", "remoteServerModel", "aiBackend",
                    "selectedEngine", "customDictionaryEnabled", "customDictionaryData",
                    "cachedRemoteModels"] {
            DefaultsStore.current.removeObject(forKey: key)
        }
    }

    func testEveryPaneFitsAtTheDefaultSizeInEveryLanguage() async throws {
        try await assertFits(size: Self.defaultSize, scale: TextScale.default)
    }

    func testEveryPaneFitsAtTheMinimumSizeInEveryLanguage() async throws {
        try await assertFits(size: Self.minimumSize, scale: TextScale.default)
    }

    func testEveryPaneFitsAtTheLargestTextSize() async throws {
        try await assertFits(size: Self.defaultSize, scale: TextScale.maximum)
    }

    // MARK: - Cases

    private struct Case {
        let tab: SettingsTab
        /// The Output pane changes with the cleanup backend, the Models pane with the engine.
        var backend = "builtin"
        var engine = "whisper"
        var name: String { "\(tab.rawValue)-\(tab == .models ? engine : backend)" }
    }

    private static var cases: [Case] {
        SettingsTab.allCases.flatMap { tab -> [Case] in
            switch tab {
            case .output: return ["builtin", "ollama", "remote"].map { Case(tab: tab, backend: $0) }
            case .models: return ["whisper", "remote"].map { Case(tab: tab, engine: $0) }
            default: return [Case(tab: tab)]
            }
        }
    }

    // MARK: - Rendering

    private func assertFits(size: CGSize, scale: Double) async throws {
        AppPreferences.shared.textScale = scale
        var failures: [String] = []
        for language in Self.languages {
            for testCase in Self.cases {
                AppPreferences.shared.aiBackend = testCase.backend
                AppPreferences.shared.selectedEngine = testCase.engine
                let name = "\(testCase.name)-\(language)-\(Int(size.width))-\(Int(scale * 100))"
                SPaneStack.overflows.removeAll()
                let (host, window) = try await render(tab: testCase.tab, language: language,
                                                      size: size, snapshot: name)
                // Closed as soon as it has been checked: a window left open keeps laying out, and
                // would report its own overflows under the name of the next render.
                defer { window.close() }
                // Layout runs several passes, so the same row can be reported more than once.
                failures += Set(SPaneStack.overflows.map {
                    "\(name): a row wants \(Int($0.row))pt in a \(Int($0.pane))pt pane"
                }).sorted()
                let views = viewsOutside(host)
                // A render with nothing in it passes every frame check, so an empty one fails.
                if views.checked < 20 {
                    failures.append("\(name): only \(views.checked) views found")
                }
                failures += views.outside.map { "\(name): \($0)" }
            }
        }
        XCTAssert(failures.isEmpty, "Outside the window:\n" + failures.joined(separator: "\n"))
    }

    private func render(tab: SettingsTab, language: String, size: CGSize,
                        snapshot name: String) async throws -> (NSView, NSWindow) {
        let root = SettingsView(initialTab: tab)
            .environment(\.locale, Locale(identifier: language))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // SwiftUI settles over a couple of passes (pickers size themselves once their items
        // arrive), so give it a moment before reading any frame.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        try writeSnapshot(of: host, named: name)
        return (host, window)
    }

    private func viewsOutside(_ host: NSView) -> (outside: [String], checked: Int) {
        var outside: [String] = []
        var checked = 0
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return }
            if view !== host, view.bounds.width > 0, view.bounds.height > 0 {
                checked += 1
                let frame = host.convert(view.bounds, from: view)
                if frame.minX < -1 || frame.maxX > host.bounds.width + 1 {
                    outside.append("\(type(of: view)) “\(describe(view))” spans x \(Int(frame.minX))…\(Int(frame.maxX))")
                }
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return (outside, checked)
    }

    private func describe(_ view: NSView) -> String {
        switch view {
        case let segmented as NSSegmentedControl:
            return (0..<segmented.segmentCount).compactMap { segmented.label(forSegment: $0) }
                .joined(separator: " | ")
        case let popup as NSPopUpButton:
            return popup.titleOfSelectedItem ?? ""
        case let field as NSTextField:
            return field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
        case let button as NSButton:
            return button.title
        default:
            return ""
        }
    }

    private func writeSnapshot(of host: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OSW_LAYOUT_SNAPSHOTS"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
enum AppMain {
    static func main() {
        // `OpenSuperWhisper transcribe <file>` runs headless and never launches the GUI (#150).
        let args = CommandLine.arguments
        if CLI.shouldHandle(args) {
            CLI.run(args)
        }
        OpenSuperWhisperApp.main()
    }
}

struct OpenSuperWhisperApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Same key as `AppPreferences.textScale`, read through @AppStorage so the window redraws
    /// when the slider moves. Reading the preference directly would not: that is what made the
    /// slider appear to do nothing in 0.10.1 (#82).
    @AppStorage("textScale") private var textScale: Double = TextScale.default

    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(width: 450)
            .frame(minHeight: 400, maxHeight: 900)
            .environmentObject(appState)
            // The main window never had this, so its history list ignored the text size
            // setting entirely while Settings obeyed it. Read through @AppStorage rather than
            // from AppPreferences: preferences aren't observed, and a value read once at window
            // construction is what made the slider look dead before (#82).
            .environment(\.appTextScale, textScale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showMainWindow()
                    }
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))

        // Dedicated, movable & closable settings window (sidebar layout).
        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 780, height: 600)
    }

    init() {
        MainThreadWatchdog.shared.start()
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
    }
}

extension OpenSuperWhisperApp {
    static func startTranscriptionQueue() {
        Task { @MainActor in
            TranscriptionQueue.shared.startProcessingQueue()
        }
    }

    static func startRetentionScheduler() {
        Task { @MainActor in
            RecordingStore.shared.startRetentionScheduler()
        }
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        var onboarding = AppPreferences.shared.hasCompletedOnboarding
        #if DEBUG
        if let force = DevConfig.shared.forceShowOnboarding {
            onboarding = !force
        }
        #endif
        self.hasCompletedOnboarding = onboarding
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    /// The app's own window, looked up rather than remembered: SwiftUI creates it after
    /// `applicationDidFinishLaunching` has run, and owns it from then on.
    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.styleMask.contains(.titled) && $0.title != "Settings" }
    }
    private var languageSubmenu: NSMenu?
    private var modelSubmenu: NSMenu?
    private var recentSubmenu: NSMenu?

    /// Rows for the "Recent" submenu, kept current by `recordingsDidUpdateNotification` rather
    /// than fetched when the menu opens: reading the store is async, and `menuNeedsUpdate` is
    /// not, so an open menu can't wait for it.
    private var recentTranscripts: [Recording] = []
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?
    
    func applicationDidFinishLaunching(_ notification: Notification) {

        setupStatusBarItem()

        // Start in the menu bar only when requested. Never during onboarding — the user needs
        // the window to finish setup.
        if AppPreferences.shared.startHidden && AppPreferences.shared.hasCompletedOnboarding {
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil)

        OpenSuperWhisperApp.startTranscriptionQueue()
        OpenSuperWhisperApp.startRetentionScheduler()
        observeMicrophoneChanges()

        // The Apple Speech locale lists are async-only; refresh the sync caches the
        // model catalog and language picker read (menu must never trigger a download).
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task.detached(priority: .utility) { await AppleSpeechSupport.refreshCaches() }
        }
#endif
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isAudioFile(url) else {
            return false
        }

        queueAudioURLs([url])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let audioURLs = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { isAudioFile($0) }

        sender.reply(toOpenOrPrint: audioURLs.isEmpty ? .failure : .success)
        queueAudioURLs(audioURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audioURLs = urls.filter { isAudioFile($0) }
        queueAudioURLs(audioURLs)
    }

    private func queueAudioURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            showMainWindow()

            for url in urls {
                await TranscriptionQueue.shared.addFileToQueue(url: url)
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
    
    private func observeMicrophoneChanges() {
        microphoneObserver = microphoneService.$availableMicrophones
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenSuperWhisper")
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        updateStatusBarMenu()

        // Registered here rather than in updateStatusBarMenu: that runs again on every language
        // or model change, so observers added there piled up one per rebuild.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferenceChanged),
            name: .appPreferencesLanguageChanged,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshRecentTranscripts),
            name: RecordingStore.recordingsDidUpdateNotification,
            object: nil)
        refreshRecentTranscripts()
    }

    private func updateStatusBarMenu() {
        let menu = NSMenu()
        
        let openItem = NSMenuItem(title: "Open Window", action: #selector(openApp), keyEquivalent: "o")
        openItem.target = self   // without a target macOS disables the item (it did nothing)
        menu.addItem(openItem)

        let transcriptionLanguageItem = NSMenuItem(title: NSLocalizedString("Language", comment: ""), action: nil, keyEquivalent: "")
        languageSubmenu = NSMenu()
        
        // Add language options — only those the active engine/model can transcribe (#155).
        let menuLanguages = EngineCapabilities.supportedLanguages(
            engine: AppPreferences.shared.selectedEngine,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion)
        for languageCode in menuLanguages {
            let languageName = LanguageUtil.languageNames[languageCode] ?? languageCode
            let languageItem = NSMenuItem(title: languageName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = languageCode
            languageItem.state = (AppPreferences.shared.whisperLanguage == languageCode) ? .on : .off
            languageSubmenu?.addItem(languageItem)
        }
        
        transcriptionLanguageItem.submenu = languageSubmenu
        menu.addItem(transcriptionLanguageItem)

        // Translation needs a Whisper-class model or a remote server; Parakeet/SenseVoice only
        // transcribe in the source language (#124). Off those, gray the item out and say why
        // instead of silently ignoring it.
        let engine = AppPreferences.shared.selectedEngine
        let translateSupported = EngineCapabilities.supportsTranslation(
            engine: engine, modelPath: AppPreferences.shared.selectedWhisperModelPath)
        let turboBlocks = engine == "whisper" && !translateSupported
        let translateItem = NSMenuItem(
            title: translateSupported
                ? NSLocalizedString("Translate to English", comment: "")
                : turboBlocks
                    ? NSLocalizedString("Translate to English (not with turbo models)", comment: "")
                    : NSLocalizedString("Translate to English (Whisper only)", comment: ""),
            action: translateSupported ? #selector(toggleTranslateToEnglish) : nil,
            keyEquivalent: "")
        translateItem.target = self
        translateItem.state = (translateSupported && AppPreferences.shared.translateToEnglish) ? .on : .off
        menu.addItem(translateItem)

        // Model picker — quick cross-engine switch. Its items are (re)built each time
        // the submenu opens (menuNeedsUpdate) so newly-downloaded or newly-fetched
        // remote models show up without relaunching. (F2)
        let modelMenuItem = NSMenuItem(title: NSLocalizedString("Model", comment: ""), action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        modelMenu.delegate = self
        modelSubmenu = modelMenu
        populateModelSubmenu()
        modelMenuItem.submenu = modelMenu
        menu.addItem(modelMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Reaching an earlier dictation otherwise means opening the main window and copying out
        // of the history list. Rebuilt on open like the model submenu, from a cache the store's
        // change notification keeps current.
        let recentItem = NSMenuItem(title: NSLocalizedString("Recent", comment: ""), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        recentMenu.delegate = self
        recentSubmenu = recentMenu
        populateRecentSubmenu()
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let microphoneMenu = NSMenuItem(title: NSLocalizedString("Microphone", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        let microphones = microphoneService.availableMicrophones
        let currentMic = microphoneService.currentMicrophone
        
        if microphones.isEmpty {
            let noDeviceItem = NSMenuItem(title: NSLocalizedString("No microphones available", comment: ""), action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        } else {
            let builtInMicrophones = microphones.filter { $0.isBuiltIn }
            let externalMicrophones = microphones.filter { !$0.isBuiltIn }
            
            for microphone in builtInMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
            
            if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            
            for microphone in externalMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
        }
        
        microphoneMenu.submenu = submenu
        menu.addItem(microphoneMenu)
        
        menu.addItem(NSMenuItem.separator())

        // No "," keyEquivalent: it makes macOS treat this as the standard Settings
        // command and auto-adds a gear icon, which the other plain items don't have.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = nil
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: ""), action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            SparkleUpdater.shared.checkForUpdates()
        }
    }

    @objc private func toggleTranslateToEnglish() {
        MainActor.assumeIsolated { TranslateStore.shared.toggle() }
        updateStatusBarMenu()
    }
    
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
        updateStatusBarMenu()
    }

    // MARK: - Model picker (F2)

    // The Model submenu opening is the moment to snapshot the app the user is in,
    // so binding a model targets the right app without requiring a recording first.
    // Opening a status-bar menu doesn't steal focus, so the frontmost app is still
    // the one the cursor is in.
    func menuWillOpen(_ menu: NSMenu) {
        RecordingContext.shared.captureFrontmost()
    }

    // Rebuild the Model submenu just before it opens, so it reflects the latest
    // downloaded/fetched models and the current selection.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === modelSubmenu {
            populateModelSubmenu()
        }
        if menu === recentSubmenu {
            populateRecentSubmenu()
        }
    }

    private func populateRecentSubmenu() {
        guard let submenu = recentSubmenu else { return }
        submenu.removeAllItems()

        guard !recentTranscripts.isEmpty else {
            let empty = NSMenuItem(title: NSLocalizedString("No transcriptions yet", comment: ""),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        for recording in recentTranscripts {
            let item = NSMenuItem(title: RecentTranscripts.menuTitle(for: recording.transcription),
                                  action: #selector(insertRecentTranscript(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = recording.transcription
            // The truncated title loses the end of a long dictation; the tooltip keeps it, so
            // picking between two that start alike doesn't need the main window.
            item.toolTip = recording.transcription
            submenu.addItem(item)
        }
    }

    @objc private func insertRecentTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Task { @MainActor in
            await PasteLastTranscript.insert(text)
        }
    }

    /// Refreshes the cache behind the "Recent" submenu. Cheap (one indexed read) and only runs
    /// when the stored recordings actually changed.
    @objc private func refreshRecentTranscripts() {
        Task { @MainActor in
            guard let recordings = try? await RecordingStore.shared.fetchRecordings(
                limit: RecentTranscripts.scanDepth, offset: 0) else { return }

            recentTranscripts = RecentTranscripts.pick(from: recordings,
                                                       limit: RecentTranscripts.menuCount)
            populateRecentSubmenu()
        }
    }

    private func populateModelSubmenu() {
        guard let submenu = modelSubmenu else { return }
        submenu.removeAllItems()

        let active = ModelCatalog.activeOption()
        let groups: [(label: String, options: [DictationModelOption])] = [
            ("Whisper", ModelCatalog.whisperModels()),
            ("Parakeet", ModelCatalog.parakeetModels()),
            ("SenseVoice", ModelCatalog.senseVoiceModels()),
            ("Remote", ModelCatalog.remoteModels()),
        ]

        var addedAnything = false
        for group in groups where !group.options.isEmpty {
            if addedAnything { submenu.addItem(NSMenuItem.separator()) }
            let header = NSMenuItem(title: group.label, action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)

            for option in group.options {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(selectModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option
                item.indentationLevel = 1
                if let active, active.engine == option.engine, active.identifier == option.identifier {
                    item.state = .on
                }
                submenu.addItem(item)
            }
            addedAnything = true
        }

        if !addedAnything {
            let none = NSMenuItem(title: NSLocalizedString("No models available", comment: ""), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? DictationModelOption else { return }
        let context = RecordingContext.shared
        // Ask the scope only when it's meaningful: context-awareness is on, there's
        // more than one model to choose between, and we're in a recognized app
        // whose current rule differs. Otherwise just set the system default.
        if AppPreferences.shared.contextAwareModelMode.prompts,
           ModelCatalog.allAvailable().count > 1,
           let bundleID = context.bundleID, let scopeLabel = context.scopeLabel,
           AppContextModelRules.rule(for: bundleID, host: context.host) != option {
            promptForModelScope(option, bundleID: bundleID, host: context.host, scopeLabel: scopeLabel)
        } else {
            MainActor.assumeIsolated { ModelSelectionStore.shared.select(option) }
        }
        populateModelSubmenu()
    }

    /// Picking a model can mean: the system default (everywhere, except apps with
    /// their own rule), the default for the current app, just the next recording in
    /// that app, or — when the app already has a rule — forgetting it. Never
    /// overwrites a rule silently.
    private func promptForModelScope(_ option: DictationModelOption, bundleID: String, host: String?, scopeLabel: String) {
        // "scope" is the most specific bindable context: the site (host) inside a
        // browser, otherwise the app.
        let hasRule = AppContextModelRules.exactRule(for: bundleID, host: host) != nil
        let alert = NSAlert()
        alert.messageText = "Apply “\(option.displayName)”?"
        alert.informativeText = "Set it as your system default, the default for \(scopeLabel), or just for your next recording."
        alert.addButton(withTitle: "System Default")
        alert.addButton(withTitle: "Default for \(scopeLabel)")
        alert.addButton(withTitle: "Just This Time")
        if hasRule {
            alert.addButton(withTitle: "Forget \(scopeLabel)’s Default")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // System default — change the active model everywhere (scopes with
            // their own rule still win); drop any pending one-time override.
            MainActor.assumeIsolated { ModelSelectionStore.shared.select(option) }
            RecordingContext.shared.clearOneTimeModel(for: bundleID)
        case .alertSecondButtonReturn:
            // Default for this scope (site or app) — apply now and persist.
            MainActor.assumeIsolated { ModelSelectionStore.shared.select(option) }
            AppContextModelRules.set(option, for: bundleID, host: host)
            RecordingContext.shared.clearOneTimeModel(for: bundleID)
        case .alertThirdButtonReturn:
            // Just this time — next recording uses it; the system default is left
            // untouched (the override fires at record-start).
            RecordingContext.shared.setOneTimeModel(option, for: bundleID)
        default:
            // Fourth button (only present when this scope has a rule): forget it so
            // it falls back to the app rule, then the system default.
            AppContextModelRules.remove(bundleID: bundleID, host: host)
            RecordingContext.shared.clearOneTimeModel(for: bundleID)
        }
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }

    @objc private func openSettings() {
        showMainWindow()
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let languageCode = sender.representedObject as? String else { return }

        // Single mutation point — persists and notifies an open Settings window.
        MainActor.assumeIsolated { LanguageStore.shared.select(languageCode) }

        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = .off
            }
            sender.state = .on
        }
    }
    
    @objc private func languagePreferenceChanged() {
        updateLanguageMenuSelection()
    }
    
    private func updateLanguageMenuSelection() {
        guard let languageSubmenu = languageSubmenu else { return }
        
        let currentLanguage = AppPreferences.shared.whisperLanguage
        
        for item in languageSubmenu.items {
            if let languageCode = item.representedObject as? String {
                item.state = (languageCode == currentLanguage) ? .on : .off
            }
        }
    }
    
    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)

        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            // No window exists (the WindowGroup window was closed, or macOS didn't
            // open it at launch — seen on macOS 26/27). Re-opening the app bundle
            // triggers the reopen handler, which makes SwiftUI re-create the window.
            // (The old `openSuperWhisper://` scheme was never declared in Info.plist,
            // so that fallback silently failed — hence the menu item doing nothing.)
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}

extension AppDelegate {
    /// Keeps the Dock icon in step with what is on screen. A window delegate cannot do this:
    /// SwiftUI owns both scenes and never hands their windows over, so the callbacks that used
    /// to live here were only ever reached by the status item's window.
    @objc func windowWillClose(_ notification: Notification) {
        // The closing window is still listed, and still visible, while this fires.
        DispatchQueue.main.async {
            let onScreen = NSApplication.shared.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled)
            }
            let policy: NSApplication.ActivationPolicy = onScreen ? .regular : .accessory
            guard NSApplication.shared.activationPolicy() != policy else { return }
            NSApplication.shared.setActivationPolicy(policy)
        }
    }
}

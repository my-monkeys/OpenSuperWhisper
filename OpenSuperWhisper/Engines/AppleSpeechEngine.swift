import AVFoundation
import Foundation
import Speech

// SpeechAnalyzer/SpeechTranscriber only exist in the macOS 26 SDK. `@available` guards
// the runtime, not compilation — so the whole engine is gated on the SDK, keyed off
// FoundationModels (a macOS-26-only framework). Older toolchains (CI's macos-latest,
// contributors on Xcode 16) build the stub below and simply never offer the engine.
#if canImport(FoundationModels)

/// Availability + locale bookkeeping for Apple's on-device speech stack
/// (SpeechAnalyzer/SpeechTranscriber, macOS 26+). Model assets are downloaded and
/// updated by the SYSTEM (AssetInventory) and shared across apps — the app never
/// stores them itself.
///
/// The framework only exposes its locale lists as async properties, but the model
/// catalog and the language picker need synchronous answers — so we cache the
/// language codes in UserDefaults, refreshed at launch and after every install.
enum AppleSpeechSupport {
    /// True when the OS ships the new Speech stack and it reports availability.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    private static let supportedKey = "appleSpeechSupportedLanguages"
    private static let installedKey = "appleSpeechInstalledLanguages"

    /// Whisper-style language codes ("en", "fr", …) the system model can transcribe.
    static var cachedSupportedLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: supportedKey) ?? []
    }

    /// Languages whose assets are installed on this Mac right now.
    static var cachedInstalledLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: installedKey) ?? []
    }

    /// The engine is usable without triggering a download (the catalog's rule:
    /// listing a model in the menu must never start one).
    static var hasInstalledModel: Bool { !cachedInstalledLanguages.isEmpty }

    @available(macOS 26.0, *)
    static func refreshCaches() async {
        let supported = languageCodes(from: await SpeechTranscriber.supportedLocales)
        let installed = languageCodes(from: await SpeechTranscriber.installedLocales)
        UserDefaults.standard.set(supported, forKey: supportedKey)
        UserDefaults.standard.set(installed, forKey: installedKey)
    }

    /// Locale list → deduplicated language codes, keeping the framework's order.
    static func languageCodes(from locales: [Locale]) -> [String] {
        var seen = Set<String>()
        return locales.compactMap { locale in
            guard let code = locale.language.languageCode?.identifier else { return nil }
            return seen.insert(code).inserted ? code : nil
        }
    }

    /// The Locale to transcribe with for the app's language setting.
    /// "auto" means the user's system language (per-transcriber locale is fixed —
    /// the system model has no cross-language auto-detect).
    @available(macOS 26.0, *)
    static func resolveLocale(language: String) async -> Locale {
        let wanted = language == "auto" ? Locale.current : Locale(identifier: language)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            return match
        }
        // Unsupported language: fall back to the first supported locale (English ships
        // everywhere) so a stale picker value degrades instead of failing the dictation.
        return await SpeechTranscriber.supportedLocales.first ?? Locale(identifier: "en_US")
    }
}

/// On-device transcription through the system speech model. No app-side model files:
/// initialize() is instant, and missing locale assets are fetched through
/// AssetInventory on first use.
@available(macOS 26.0, *)
final class AppleSpeechEngine: TranscriptionEngine {
    var engineName: String { "Apple Speech" }
    private(set) var isModelLoaded = false
    private var currentAnalyzer: SpeechAnalyzer?

    func initialize() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.contextInitializationFailed
        }
        isModelLoaded = true
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        let locale = await AppleSpeechSupport.resolveLocale(language: settings.selectedLanguage)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Settings installs assets up front, but a language switched from the menu bar
        // may not have them yet — fetch now rather than fail the dictation.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
            await AppleSpeechSupport.refreshCaches()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        currentAnalyzer = analyzer
        defer { currentAnalyzer = nil }

        let file = try AVAudioFile(forReading: url)

        // Start draining results before feeding audio — the sequence ends when the
        // analyzer finishes, which is what terminates the collector.
        async let collected = Self.collectFinalText(from: transcriber)
        try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        var text = try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.shouldApplyAsianAutocorrect && !text.isEmpty {
            text = AutocorrectWrapper.format(text)
        }
        if settings.shouldApplyCustomDictionary {
            text = CustomDictionary.apply(text, entries: settings.customDictionaryEntries)
        }
        return text.isEmpty ? TranscriptionResult.noSpeech : text
    }

    private static func collectFinalText(from transcriber: SpeechTranscriber) async throws -> String {
        var out = ""
        for try await result in transcriber.results where result.isFinal {
            out += String(result.text.characters)
        }
        return out
    }

    func cancelTranscription() {
        guard let analyzer = currentAnalyzer else { return }
        Task { await analyzer.cancelAndFinishNow() }
    }

    func getSupportedLanguages() -> [String] {
        EngineCapabilities.supportedLanguages(engine: "apple", fluidAudioModelVersion: "")
    }
}

#else

/// Old-SDK stub: the engine is never supported, so no UI or catalog entry appears
/// and none of the SpeechAnalyzer symbols are referenced.
enum AppleSpeechSupport {
    static var isSupported: Bool { false }
    static var cachedSupportedLanguages: [String] { [] }
    static var cachedInstalledLanguages: [String] { [] }
    static var hasInstalledModel: Bool { false }
}

#endif

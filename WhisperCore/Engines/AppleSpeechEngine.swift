import AVFoundation
import Foundation
import Speech

// SpeechAnalyzer/SpeechTranscriber only exist in the macOS 26 SDK. `@available` guards
// the runtime, not compilation — so the whole engine is gated on the SDK, keyed off
// FoundationModels (a macOS-26-only framework). Older toolchains (CI's macos-latest,
// contributors on Xcode 16) build the stub below and simply never offer the engine.
#if os(macOS) && canImport(FoundationModels)

/// Availability + locale bookkeeping for Apple's on-device speech stack
/// (SpeechAnalyzer/SpeechTranscriber, macOS 26+). Model assets are downloaded and
/// updated by the SYSTEM (AssetInventory) and shared across apps — the app never
/// stores them itself.
///
/// The framework only exposes its locale lists as async properties, but the model
/// catalog and the language picker need synchronous answers — so we cache the
/// language codes in UserDefaults, refreshed at launch and after every install.
public enum AppleSpeechSupport {
    /// True when the OS ships the new Speech stack and it reports availability.
    public static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    private static let supportedKey = "appleSpeechSupportedLanguages"
    private static let installedKey = "appleSpeechInstalledLanguages"

    /// Whisper-style language codes ("en", "fr", …) the system model can transcribe.
    public static var cachedSupportedLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: supportedKey) ?? []
    }

    /// Languages whose assets are installed on this Mac right now.
    public static var cachedInstalledLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: installedKey) ?? []
    }

    /// The engine is usable without triggering a download (the catalog's rule:
    /// listing a model in the menu must never start one).
    public static var hasInstalledModel: Bool { !cachedInstalledLanguages.isEmpty }

    @available(macOS 26.0, *)
    public static func refreshCaches() async {
        let supported = languageCodes(from: await SpeechTranscriber.supportedLocales)
        let installed = languageCodes(from: await SpeechTranscriber.installedLocales)
        UserDefaults.standard.set(supported, forKey: supportedKey)
        UserDefaults.standard.set(installed, forKey: installedKey)
    }

    /// Locale list → deduplicated language codes, keeping the framework's order.
    public static func languageCodes(from locales: [Locale]) -> [String] {
        var seen = Set<String>()
        return locales.compactMap { locale in
            guard let code = locale.language.languageCode?.identifier else { return nil }
            return seen.insert(code).inserted ? code : nil
        }
    }

    /// Install the locale's assets if they're missing. The system caps reserved
    /// locales ("Too many allocated locales, 5 maximum") — when the quota is full,
    /// release one we're not about to use and retry once. `onProgress` exposes the
    /// system download's Progress for UI.
    @available(macOS 26.0, *)
    public static func installAssetsIfNeeded(supporting transcriber: SpeechTranscriber, locale: Locale,
                                      onProgress: ((Foundation.Progress) -> Void)? = nil) async throws {
        do {
            try await installOnce(transcriber, onProgress: onProgress)
        } catch {
            let reserved = await AssetInventory.reservedLocales
            guard let victim = reserved.first(where: { $0.identifier != locale.identifier }) else {
                throw error
            }
            _ = await AssetInventory.release(reservedLocale: victim)
            try await installOnce(transcriber, onProgress: onProgress)
        }
        await refreshCaches()
    }

    @available(macOS 26.0, *)
    private static func installOnce(_ transcriber: SpeechTranscriber,
                                    onProgress: ((Foundation.Progress) -> Void)?) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        onProgress?(request.progress)
        try await request.downloadAndInstall()
    }

    /// Per-language regional overrides ("fr" → "fr_CH"), chosen by the user in the
    /// Models pane. Absent = the canonical CLDR resolution below.
    private static let overridesKey = "appleSpeechLocaleOverrides"
    public static var localeOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: overridesKey) }
    }

    /// The effective language code for the app's language setting ("auto" = system).
    public static func effectiveLanguageCode(for language: String) -> String {
        language == "auto"
            ? (Locale.current.language.languageCode?.identifier ?? "en")
            : language
    }

    /// All supported regional variants of one language (fr → fr_FR, fr_CH, fr_CA, fr_BE),
    /// for the Models pane's variant picker.
    @available(macOS 26.0, *)
    public static func supportedVariants(for language: String) async -> [Locale] {
        let code = effectiveLanguageCode(for: language)
        return await SpeechTranscriber.supportedLocales
            .filter { $0.language.languageCode?.identifier == code }
            .sorted { $0.identifier < $1.identifier }
    }

    /// The Locale to transcribe with for the app's language setting.
    /// "auto" means the user's system language (per-transcriber locale is fixed —
    /// the system model has no cross-language auto-detect).
    @available(macOS 26.0, *)
    public static func resolveLocale(language: String) async -> Locale {
        // A user-chosen regional variant wins (Models → Apple → Regional variant).
        if let overrideID = localeOverrides[effectiveLanguageCode(for: language)],
           let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: overrideID)) {
            return match
        }
        let wanted: Locale
        if language == "auto" {
            wanted = Locale.current
        } else {
            // The picker's bare Whisper codes ("fr") name no region, and the framework's
            // equivalence then picks an arbitrary supported variant (fr → fr_CA or fr_CH).
            // CLDR likely-subtags ("fr" → fr-Latn-FR) land each language on its canonical
            // region: fr_FR, en_US, pt_BR, zh_CN (Simplified), …
            wanted = Locale(identifier: Locale.Language(identifier: language).maximalIdentifier)
        }
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
public final class AppleSpeechEngine: TranscriptionEngine {
    public var engineName: String { "Apple Speech" }
    public private(set) var isModelLoaded = false
    private var currentAnalyzer: SpeechAnalyzer?

    public func initialize() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.contextInitializationFailed
        }
        isModelLoaded = true
    }

    public func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        let locale = await AppleSpeechSupport.resolveLocale(language: settings.selectedLanguage)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Settings installs assets up front, but a language switched from the menu bar
        // may not have them yet — fetch now rather than fail the dictation.
        try await AppleSpeechSupport.installAssetsIfNeeded(supporting: transcriber, locale: locale)

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

    public func cancelTranscription() {
        guard let analyzer = currentAnalyzer else { return }
        Task { await analyzer.cancelAndFinishNow() }
    }

    public func getSupportedLanguages() -> [String] {
        EngineCapabilities.supportedLanguages(engine: "apple", fluidAudioModelVersion: "")
    }
}

#else

/// Old-SDK stub: the engine is never supported, so no UI or catalog entry appears
/// and none of the SpeechAnalyzer symbols are referenced.
public enum AppleSpeechSupport {
    public static var isSupported: Bool { false }
    public static var cachedSupportedLanguages: [String] { [] }
    public static var cachedInstalledLanguages: [String] { [] }
    public static var hasInstalledModel: Bool { false }
}

#endif

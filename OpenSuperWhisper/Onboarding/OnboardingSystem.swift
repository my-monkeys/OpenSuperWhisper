import Foundation
import Speech
import FluidAudio
import OpenSuperWhisperCore

/// What onboarding reads from this Mac: which models are on disk, what Apple's speech model
/// offers, the languages the user works in. Live in the app; the tests and the snapshot probe
/// stage it, so neither ever reads the owner's models.
struct OnboardingSystem {
    var isDownloaded: (OnboardingModelType) -> Bool
    var appleSpeech: (_ language: String) async -> AppleSpeechOffer
    /// The localization the app is running in ("fr").
    var appLanguage: String?
    var preferredLanguages: [String]
    /// The Mac account's full name, offered as a word to add. Empty when the account has none.
    var fullUserName: String

    static let live = OnboardingSystem(
        isDownloaded: isDownloadedOnDisk,
        appleSpeech: currentAppleSpeechOffer,
        appLanguage: Bundle.main.preferredLocalizations.first,
        preferredLanguages: Locale.preferredLanguages,
        fullUserName: NSFullUserName())

    /// Fixed answers, nothing read from disk or from the system. Apple's offer is asked per
    /// language, so a test can switch to one it does not speak.
    static func staged(downloaded: @escaping (OnboardingModelType) -> Bool = { _ in false },
                       appleSpeech: @escaping (_ language: String) -> AppleSpeechOffer = { _ in .unavailable },
                       appLanguage: String? = "en",
                       fullUserName: String = "") -> OnboardingSystem {
        OnboardingSystem(isDownloaded: downloaded,
                         appleSpeech: { appleSpeech($0) },
                         appLanguage: appLanguage,
                         preferredLanguages: [appLanguage ?? "en"],
                         fullUserName: fullUserName)
    }

    private static func isDownloadedOnDisk(_ type: OnboardingModelType) -> Bool {
        switch type {
        case .whisper(let url, _):
            return WhisperModelManager.shared.isModelDownloaded(name: url.lastPathComponent)
        case .parakeet(let version):
            return isFluidAudioModelDownloaded(version: version)
        case .senseVoice:
            return SenseVoiceModelManager.shared.isDownloaded
        case .appleSpeech:
            return false
        }
    }

    private static func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion = AsrModelVersion(preference: version)
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }

    /// Same rules as Settings → Models → Apple: the macOS 26 SDK and runtime, a language the
    /// system model speaks, and "installed" meaning on this Mac, not merely reserved for the app
    /// (#46).
    private static func currentAppleSpeechOffer(language: String) async -> AppleSpeechOffer {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), AppleSpeechSupport.isSupported else { return .unavailable }
        let code = AppleSpeechSupport.effectiveLanguageCode(for: language)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.language.languageCode?.identifier == code }) else {
            return .unavailable
        }
        let locale = await AppleSpeechSupport.resolveLocale(language: language)
        let installed = await SpeechTranscriber.installedLocales
        return LanguageUtil.isInstalled(locale, in: installed) ? .installed : .systemDownload
        #else
        return .unavailable
        #endif
    }
}

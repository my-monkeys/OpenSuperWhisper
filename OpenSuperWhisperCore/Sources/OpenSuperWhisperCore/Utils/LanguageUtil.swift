import Foundation
public class LanguageUtil {

    /// Every language the bundled Whisper build can transcribe, read from the library instead of
    /// hand-listed.
    ///
    /// The hand-written list held 22 of Whisper's 99 languages, and the missing ones only ever
    /// surfaced as user reports: Ukrainian, then Vietnamese (#74), then Czech. Each was a
    /// language Whisper had handled all along that nobody could select. Reading the table the
    /// transcriber actually uses ends that class of bug rather than its latest instance.
    public static let availableLanguages: [String] = {
        ["auto"] + whisperCodes.sorted { displayName(for: $0) < displayName(for: $1) }
    }()

    public static let languageNames: [String: String] = {
        var names = curatedNames
        for code in whisperCodes {
            names[code] = displayName(for: code)
        }
        return names
    }()

    /// Whisper's own names are lowercase and occasionally terse, so ours win where we have one.
    public static func displayName(for code: String) -> String {
        curatedNames[code] ?? whisperName(for: code) ?? code
    }

    private static let whisperCodes: [String] = {
        let maxId = MyWhisperContext.langMaxId()
        guard maxId >= 0 else { return [] }
        return (0...maxId).compactMap { MyWhisperContext.langStr(id: $0) }
    }()

    private static func whisperName(for code: String) -> String? {
        let id = MyWhisperContext.langId(lang: code)
        guard id >= 0, let full = MyWhisperContext.langStrFull(id: id) else { return nil }
        return full.capitalized
    }

    private static let curatedNames = [
        "auto": "Auto-detect",
        "en": "English",
        "zh": "Chinese",
        "de": "German",
        "es": "Spanish",
        "ru": "Russian",
        "ko": "Korean",
        "fr": "French",
        "ja": "Japanese",
        "pt": "Portuguese",
        "tr": "Turkish",
        "pl": "Polish",
        "ca": "Catalan",
        "nl": "Dutch",
        "ar": "Arabic",
        "he": "Hebrew",
        "sv": "Swedish",
        "it": "Italian",
        "id": "Indonesian",
        "hi": "Hindi",
        "fi": "Finnish",
        "vi": "Vietnamese",
    ]

    public static func getSystemLanguage() -> String {
        if let preferredLanguage = Locale.preferredLanguages.first {
            let preferredLanguage = preferredLanguage.prefix(2).lowercased()
            return availableLanguages.contains(preferredLanguage) ? preferredLanguage : "en"
        } else {
            return "eng"
        }
    }

    /// Whether `locale` appears in `installed`, comparing language and region rather than raw
    /// identifiers. Speech hands the same locale back as "fr_FR" or "fr-FR" depending on the
    /// call, so a string compare reports a downloaded model as missing. A region-less locale
    /// ("fr") matches any region of that language, which is what the language rows ask about.
    public static func isInstalled(_ locale: Locale, in installed: [Locale]) -> Bool {
        installed.contains { matches($0, locale) }
    }

    static func matches(_ a: Locale, _ b: Locale) -> Bool {
        guard a.language.languageCode == b.language.languageCode else { return false }
        guard let wanted = b.region else { return true }
        return a.region == wanted
    }
}

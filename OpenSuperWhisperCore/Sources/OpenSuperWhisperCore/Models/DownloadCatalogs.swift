import Foundation

public struct SettingsDownloadableModel: Identifiable {
    public let id = UUID()
    public let name: String
    public var isDownloaded: Bool
    public let url: URL
    public let size: Int
    public let description: String
    public var downloadProgress: Double = 0.0
    /// On-disk filename. Defaults to the URL's basename, but some sources (e.g. the ivrit.ai
    /// model served as a generic `ggml-model.bin`) need an explicit, distinct name.
    public let filename: String
    /// Language to switch to when this model is selected (e.g. "he" for the Hebrew model).
    public let preferredLanguage: String?

    public var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1000000)
    }

    public init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
    }
}

public struct SettingsDownloadableModels {
    public static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        ),
        // The only models here that translate. Every Turbo build above returns the source
        // language unchanged with the translate task set, measured on the same clip, so until
        // these existed there was no configuration in the app that could translate at all. Two
        // users found that out the hard way and one went and installed a model by hand (#86).
        SettingsDownloadableModel(
            name: "Large v3 — translates",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin?download=true")!,
            size: 2951,
            description: "Slower than Turbo, and the most accurate. Can translate to English"
        ),
        SettingsDownloadableModel(
            name: "Medium — translates",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin?download=true")!,
            size: 1462,
            description: "A middle ground. Can translate to English"
        ),
        SettingsDownloadableModel(
            name: "Small — translates",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=true")!,
            size: 465,
            description: "Light, less accurate. Can translate to English"
        ),
        // Distil large-v3 was here briefly — dropped after our FLEURS benchmark: on
        // Metal it matches large-v3-turbo's speed exactly (the shared large encoder
        // dominates short dictation clips) with worse accuracy (8% vs 5.9% WER) and
        // English only. Anyone who downloaded it keeps using it via the on-disk list.
        SettingsDownloadableModel(
            name: "Hebrew — ivrit.ai Turbo v3",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew-optimized model by ivrit.ai. Selecting it sets the language to Hebrew.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he"
        )
    ]

    public static func preferredLanguage(forFilename filename: String) -> String? {
        availableModels.first { $0.filename == filename }?.preferredLanguage
    }
}

public struct SettingsFluidAudioModel: Identifiable {
    public let id = UUID()
    public let name: String
    public let version: String
    public var isDownloaded: Bool
    public let description: String
    public var size: Int = 0   // approximate download size, MB
    public var downloadProgress: Double = 0.0

    public var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1_000_000)
    }
}

public struct SettingsFluidAudioModels {
    public static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 461
        ),
        SettingsFluidAudioModel(
            name: "Parakeet Ultra",
            version: "ultra",
            isDownloaded: false,
            description: "Multilingual, 25 languages, most accurate",
            size: 614
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 460
        )
    ]
}

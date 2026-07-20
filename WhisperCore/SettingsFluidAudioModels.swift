import Foundation

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
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 460
        )
    ]
}

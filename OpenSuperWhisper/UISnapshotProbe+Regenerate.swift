#if DEBUG
import SwiftUI
import OpenSuperWhisperCore

/// The regenerate panel (#276). The off-screen probe cannot open the popover through a click, so
/// the panel view is drawn directly, on a made-up set of models and engines.
@MainActor
extension UISnapshotProbe {
    static let regenerateScreens: [String: () -> AnyView] = [
        "regenerate-audio": { regeneratePanel(.audio) },
        "regenerate-cleanup": { regeneratePanel(.cleanup) },
        "regenerate-cleanup-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return regeneratePanel(.cleanup)
        },
        "regenerate-audio-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return regeneratePanel(.audio)
        },
    ]

    private static func regeneratePanel(_ tab: RegeneratePanel.Tab) -> AnyView {
        guard let recording = reportedRecording else { return AnyView(EmptyView()) }
        func option(_ engine: String, _ id: String, _ name: String) -> DictationModelOption {
            DictationModelOption(engine: engine, identifier: id, displayName: name)
        }
        let models = [
            RegenerationModel(family: .parakeet, option: option("fluidaudio", "v3", "Parakeet v3")),
            RegenerationModel(family: .parakeet, option: option("fluidaudio", "v2", "Parakeet v2")),
            RegenerationModel(family: .whisper, option: option("whisper", "a", "Whisper large-v3-turbo")),
            RegenerationModel(family: .whisper, option: option("whisper", "b", "Whisper small")),
            RegenerationModel(family: .senseVoice, option: option("sensevoice", "default", "SenseVoice")),
            RegenerationModel(family: .appleSpeech, option: option("applespeech", "fr-FR", "Apple Speech (Français)")),
            RegenerationModel(family: .remote, option: option("remote", "whisper-large-v3", "whisper-large-v3")),
        ]
        let backends = CleanupBackendOptions.available(.init(
            appleIntelligenceAvailable: true, builtInModelLabel: "Qwen 3 4B",
            ollamaEndpoint: "http://localhost:11434", ollamaModel: "llama3.2",
            remoteEndpoint: "https://openrouter.ai/api/v1", remoteModel: "google/gemini-2.5-flash-lite"))
        return AnyView(
            RegeneratePanel(recording: recording, tab: tab, models: models, backends: backends,
                            hasAudio: true, cleanupAvailable: true)
                .environment(\.appTextScale, AppPreferences.shared.textScale)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(STheme.sidebarBg)
        )
    }
}
#endif

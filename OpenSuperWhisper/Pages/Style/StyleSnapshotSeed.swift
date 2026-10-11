#if DEBUG
import Foundation
import OpenSuperWhisperCore

extension UISnapshotProbe {
    /// Made-up per-app rules for the Style screens, written to the isolated preferences before
    /// the page's view model reads them.
    static func seedStyle(expandFirst: Bool = false) {
        let prefs = AppPreferences.shared
        prefs.appInsertionRules = [
            AppInsertionRule(bundleIdentifier: "com.apple.mail", appName: "Mail", mode: .paste),
            AppInsertionRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", mode: .type,
                             typingPaceMilliseconds: 2),
        ]
        prefs.appContextProfiles = AppContextProfile.defaultPresets
        let parakeet = DictationModelOption(engine: "fluidaudio", identifier: "v3", displayName: "Parakeet v3")
        let turbo = DictationModelOption(engine: "whisper", identifier: "/tmp/ggml-large-v3-turbo.bin",
                                         displayName: "Whisper turbo")
        prefs.appModelRulesData = (try? JSONEncoder().encode([
            "com.apple.Terminal": parakeet,
            "com.apple.mail": turbo,
            "com.apple.Safari|github.com": parakeet,
        ])) ?? Data()
        StylePage.snapshotExpandsFirstRow = expandFirst
    }
}
#endif

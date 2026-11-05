#if DEBUG
import Foundation
import OpenSuperWhisperCore

extension UISnapshotProbe {
    /// Made-up per-app rules for the Per app screens, written to the isolated preferences before
    /// the page's view model reads them.
    static func seedPerApp(expandFirst: Bool = false, expandFirstSite: Bool = false,
                           typedWithLayout: Bool = false) {
        let prefs = AppPreferences.shared
        prefs.appInsertionRules = [
            AppInsertionRule(bundleIdentifier: "com.apple.mail", appName: "Mail", mode: .paste),
            AppInsertionRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", mode: .type,
                             typingPaceMilliseconds: 2),
        ]
        if typedWithLayout {
            // Sorts first, so the expanded row is the one with a Keyboard menu.
            prefs.appInsertionRules.append(AppInsertionRule(
                bundleIdentifier: "com.google.Chrome.app.remote", appName: "Chrome Remote Desktop",
                mode: .type, keyboardLayoutID: RemoteKeyboardLayouts.usLayoutID))
        }
        prefs.appContextProfiles = AppContextProfile.defaultPresets
        prefs.appWritingStyles = [
            "com.apple.mail": WritingStyle.proID,
            "company.thebrowser.dia|mail.google.com": WritingStyle.proID,
        ]
        prefs.appCleanupOverrides = [
            "com.apple.notes": true,
            "company.thebrowser.dia|mail.google.com": true,
            "company.thebrowser.dia": false,
        ]
        prefs.perAppDisabledBundleIDs = AppContextProfile.defaultPresets.map(\.bundleIdentifier)
            .filter { $0 != "com.apple.Terminal" && $0 != "com.apple.mail" }
        let parakeet = DictationModelOption(engine: "fluidaudio", identifier: "v3", displayName: "Parakeet v3")
        let turbo = DictationModelOption(engine: "whisper", identifier: "/tmp/ggml-large-v3-turbo.bin",
                                         displayName: "Whisper turbo")
        prefs.appModelRulesData = (try? JSONEncoder().encode([
            "com.apple.Terminal": parakeet,
            "com.apple.mail": turbo,
            "com.apple.Safari|github.com": parakeet,
        ])) ?? Data()
        PerAppPage.snapshotExpandsFirstRow = expandFirst
        PerAppPage.snapshotExpandsFirstSite = expandFirstSite
    }
}
#endif

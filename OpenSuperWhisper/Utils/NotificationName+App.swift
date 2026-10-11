import Foundation

extension Notification.Name {
    static let appPreferencesLanguageChanged = Notification.Name("AppPreferencesLanguageChanged")
    static let hotkeySettingsChanged = Notification.Name("HotkeySettingsChanged")
    /// ⌘F on the Transcriptions tab: the window's shortcut lives in the Settings sidebar, but
    /// on that tab the search the user means is the one over their transcriptions.
    static let focusTranscriptionSearch = Notification.Name("FocusTranscriptionSearch")
    /// "Settings…" and ⌘,: leave the Transcriptions tab for a settings pane. The window is both
    /// now, so bringing it forward alone would land on the list.
    static let showSettingsPane = Notification.Name("ShowSettingsPane")
    /// The status menu's "Transcriptions" item.
    static let showTranscriptions = Notification.Name("ShowTranscriptions")
    static let indicatorWindowDidHide = Notification.Name("IndicatorWindowDidHide")
    /// Posted when Translate-to-English changes (via TranslateStore), so an open Settings
    /// window re-syncs. Language reuses `appPreferencesLanguageChanged`.
    static let translateSettingDidChange = Notification.Name("TranslateSettingDidChange")
}

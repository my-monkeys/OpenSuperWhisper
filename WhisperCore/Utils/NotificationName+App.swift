import Foundation

public extension Notification.Name {
    static let appPreferencesLanguageChanged = Notification.Name("AppPreferencesLanguageChanged")
    static let hotkeySettingsChanged = Notification.Name("HotkeySettingsChanged")
    static let indicatorWindowDidHide = Notification.Name("IndicatorWindowDidHide")
    static let openSettings = Notification.Name("OpenSettings")
    /// Posted when the active engine/model changes outside the Settings view (the
    /// menu-bar Model picker), so an open Settings window re-syncs from AppPreferences.
    static let modelSelectionDidChange = Notification.Name("ModelSelectionDidChange")
    /// Posted when Translate-to-English changes (via TranslateStore), so an open Settings
    /// window re-syncs. Language reuses `appPreferencesLanguageChanged`.
    static let translateSettingDidChange = Notification.Name("TranslateSettingDidChange")
}

import Foundation

/// Notification names with at least one WhisperCore poster or observer. App-internal
/// names (hotkeys, indicator window, settings window) live app-side in
/// `OpenSuperWhisper/Utils/NotificationName+App.swift`.
public extension Notification.Name {
    static let appPreferencesLanguageChanged = Notification.Name("AppPreferencesLanguageChanged")
    /// Posted when the active engine/model changes outside the Settings view (the
    /// menu-bar Model picker), so an open Settings window re-syncs from AppPreferences.
    static let modelSelectionDidChange = Notification.Name("ModelSelectionDidChange")
    /// Posted when Translate-to-English changes (via TranslateStore), so an open Settings
    /// window re-syncs. Language reuses `appPreferencesLanguageChanged`.
    static let translateSettingDidChange = Notification.Name("TranslateSettingDidChange")
}

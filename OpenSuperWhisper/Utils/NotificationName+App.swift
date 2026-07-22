import Foundation

/// App-internal notification names (macOS app only — no WhisperCore poster or observer).
/// Names with a core consumer live in WhisperCore's `NotificationName+App.swift`.
/// String values are unchanged from the pre-relocation definitions.
extension Notification.Name {
    static let hotkeySettingsChanged = Notification.Name("HotkeySettingsChanged")
    static let indicatorWindowDidHide = Notification.Name("IndicatorWindowDidHide")
    static let openSettings = Notification.Name("OpenSettings")
}

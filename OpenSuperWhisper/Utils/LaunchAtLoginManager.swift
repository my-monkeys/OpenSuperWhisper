import AppKit
import ServiceManagement

/// Manages whether the app launches automatically when the user logs in.
///
/// Uses `SMAppService.mainApp` (macOS 13+), which registers the main app
/// itself as a login item — no separate helper bundle required. The published
/// `isEnabled` always reflects the real, system-reported registration state.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool

    private init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Whether macOS opened the app at login, rather than someone opening it. Read from the
    /// launch's Apple event, which is only current early in `applicationDidFinishLaunching`.
    /// Also true for a login item added by hand in System Settings, not only through our toggle.
    nonisolated static var wasLaunchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Re-reads the current state from the system. Call this when the settings
    /// window appears, in case the user changed the login item elsewhere.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Enables or disables launch-at-login, then syncs `isEnabled` to the
    /// resulting system state so the UI reflects what actually happened.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("Failed to update Launch at Login: \(error)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

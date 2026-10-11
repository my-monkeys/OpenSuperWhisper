import AppKit
import SwiftUI

/// Step 3: what macOS has to allow, each with its reason and the button that asks. The status
/// updates live: PermissionsManager polls while the window is key, and the onboarding re-reads
/// Input Monitoring on the same beat. Nothing here blocks, the main window's status card asks
/// again for anything still missing.
struct OnboardingPermissionsStep: View {
    @ObservedObject var permissions: PermissionsManager
    let needsInputMonitoring: Bool
    let inputMonitoringGranted: Bool
    let allGranted: Bool

    private static let inputMonitoringPane =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Permissions") {
                SettingRow("Microphone", hint: "To hear you.") {
                    if permissions.isMicrophonePermissionGranted {
                        GrantedLabel()
                    } else {
                        Button("Allow") { permissions.requestMicrophonePermissionOrOpenSystemPreferences() }
                            .buttonStyle(.sPrimary)
                    }
                }
                SettingRow("Accessibility", hint: "To type your words into other apps.") {
                    if permissions.isAccessibilityPermissionGranted {
                        GrantedLabel()
                    } else {
                        Button("Open System Settings") { permissions.openSystemPreferences(for: .accessibility) }
                            .buttonStyle(.sSecondary)
                    }
                }
                if needsInputMonitoring {
                    SettingRow("Input Monitoring",
                               hint: "To notice right ⌥ while another app is in front. macOS asks once, when the app starts listening for the key. Only modifier keys are watched.") {
                        if inputMonitoringGranted {
                            GrantedLabel()
                        } else {
                            Button("Open System Settings") { NSWorkspace.shared.open(Self.inputMonitoringPane) }
                                .buttonStyle(.sSecondary)
                        }
                    }
                }
            }

            if allGranted {
                OnboardingCallout {
                    Text("All set. OpenSuperWhisper can hear you and type for you.")
                }
            } else {
                OnboardingCallout {
                    Text("You can do this later. Until then, the main window shows what is missing in its status card.")
                }
            }
        }
    }
}

/// The state of a permission macOS has already granted.
private struct GrantedLabel: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark")
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.ok)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.okBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.okBorder, lineWidth: 1))
            .fixedSize()
    }
}

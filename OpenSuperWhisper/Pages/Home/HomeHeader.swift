import SwiftUI
import OpenSuperWhisperCore

/// "Hello Maxim" and how to dictate, with the real trigger.
struct HomeGreeting: View {
    let trigger: HomeTriggerSummary?

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if firstName.isEmpty {
                    Text("Hello")
                } else {
                    Text("Hello \(firstName)")
                }
            }
            .scaledFont(size: 30, weight: .bold)
            .foregroundColor(STheme.textBright)
            Text(instructions)
                .scaledFont(size: 16)
                .foregroundColor(STheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The key is bold and brighter than the sentence around it, as in the design.
    private var instructions: AttributedString {
        let markdown: String
        if let trigger {
            markdown = trigger.holds
                ? String(localized: "Hold **\(trigger.label)**, speak, release. The text lands where you type.")
                : String(localized: "Press **\(trigger.label)**, speak, press it again. The text lands where you type.")
        } else {
            markdown = String(localized: "Click the record button, speak, click it again. The text lands where you type.")
        }
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range].foregroundColor = STheme.textBright
        }
        return text
    }
}

/// The three beige tiles under the greeting: shortcut, active model, style.
struct HomeSummaryTiles: View {
    let trigger: HomeTriggerSummary?
    @ObservedObject private var models = ModelSelectionStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SummaryTile(label: "Shortcut", action: { AppNavigation.shared.openSettings(.dictation) }) {
                Text(shortcutValue)
            }
            .help("Change the shortcut in Settings")
            SummaryTile(label: "Active model", action: { AppNavigation.shared.openSettings(.models) }) {
                Text(modelValue)
            }
            .help("Choose the model in Settings")
            SummaryTile(label: "Style", soon: true, action: nil) {
                Text("Writing styles")
                    .foregroundColor(STheme.faint)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutValue: String {
        guard let trigger else { return String(localized: "None set") }
        return trigger.holds
            ? String(localized: "\(trigger.label) · hold")
            : String(localized: "\(trigger.label) · toggle")
    }

    private var modelValue: String {
        guard let model = models.active else { return String(localized: "No model chosen") }
        return model.engine == "remote"
            ? String(localized: "\(model.displayName) · server")
            : String(localized: "\(model.displayName) · local")
    }
}

private struct SummaryTile<Value: View>: View {
    let label: LocalizedStringKey
    var soon = false
    let action: (() -> Void)?
    @ViewBuilder let value: () -> Value
    @State private var hovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { tile }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
            } else {
                tile
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                if soon { SoonBadge() }
            }
            value()
                .scaledFont(size: 17, weight: .semibold)
                .foregroundColor(STheme.textBright)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(STheme.fill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(hovered ? STheme.controlBorder : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Replaces the old full-screen permissions gate: the history stays readable, and the banner
/// names what is missing with the button that fixes it.
struct HomePermissionBanners: View {
    @ObservedObject var permissions: PermissionsManager

    private var anyMissing: Bool {
        !permissions.isMicrophonePermissionGranted || !permissions.isAccessibilityPermissionGranted
    }

    var body: some View {
        if anyMissing {
            VStack(spacing: 10) {
                if !permissions.isMicrophonePermissionGranted {
                    PermissionBanner(
                        title: "Microphone not allowed",
                        detail: "OpenSuperWhisper can't hear you until you allow the microphone in System Settings.",
                        action: { permissions.requestMicrophonePermissionOrOpenSystemPreferences() })
                }
                if !permissions.isAccessibilityPermissionGranted {
                    PermissionBanner(
                        title: "Accessibility not allowed",
                        detail: "Without it, the shortcuts don't work outside the app and the text can't be typed where you write.",
                        action: { permissions.openSystemPreferences(for: .accessibility) })
                }
            }
            // Rechecks for as long as a banner is up. The manager's own polling follows window
            // key changes, and Home is built at launch, before onboarding grants the microphone:
            // without this the banner kept asking for a permission the app already had.
            .task {
                while !Task.isCancelled {
                    permissions.checkMicrophonePermission()
                    permissions.checkAccessibilityPermission()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}

private struct PermissionBanner: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 15)
                .foregroundColor(STheme.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(STheme.warn)
                Text(detail)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open System Settings", action: action)
                .buttonStyle(.sSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(STheme.warnBorder, lineWidth: 1))
    }
}

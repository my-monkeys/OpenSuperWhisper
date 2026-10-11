import SwiftUI
import OpenSuperWhisperCore

/// Step 1: how dictation starts. The key combination stays the default because it needs no
/// permission; right ⌥ is simpler to press but macOS has to let the app watch modifier keys.
struct OnboardingShortcutStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let layoutInfo: KeyboardLayoutInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                ShortcutChoiceCard(
                    keys: OnboardingShortcutLabel.rightOption,
                    title: "The right Option key",
                    detail: "Simple. Needs a macOS permission.",
                    selected: viewModel.selectedShortcut == .rightOption
                ) { viewModel.selectedShortcut = .rightOption }
                ShortcutChoiceCard(
                    keys: OnboardingShortcutLabel.combination(layout: layoutInfo),
                    title: "A key combination",
                    detail: "No extra permission.",
                    selected: viewModel.selectedShortcut == .keyCombination
                ) { viewModel.selectedShortcut = .keyCombination }
            }
            .fixedSize(horizontal: false, vertical: true)

            OnboardingCallout {
                Text("Hold to talk, release to finish. A short tap works too: tap to start, tap again to stop.")
                if viewModel.selectedShortcut == .rightOption {
                    Text("macOS will ask for Input Monitoring so the app can notice this key in other apps. Only modifier keys are watched, never what you type.")
                } else {
                    Text("Key combinations need no extra permission.")
                }
            }

            if let layoutInfo {
                // Fixed widths, so it shrinks in a narrow window instead of running past it.
                ViewThatFits(in: .horizontal) {
                    OnboardingKeyboardView(selectedShortcut: viewModel.selectedShortcut,
                                           layoutInfo: layoutInfo, width: 480)
                    OnboardingKeyboardView(selectedShortcut: viewModel.selectedShortcut,
                                           layoutInfo: layoutInfo, width: 360)
                }
            }

            Text("You can change it, or add more shortcuts, in Settings later.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
        }
    }
}

/// How the two shortcut choices are spelled on screen.
enum OnboardingShortcutLabel {
    static let rightOption = "Right ⌥"

    /// The combination the app actually listens to, else the default one (⌥ and the key left of
    /// 1) in the user's keyboard layout.
    @MainActor static func combination(layout: KeyboardLayoutInfo?) -> String {
        let combo = RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers).triggers
            .first { if case .keyCombo = $0 { return true } else { return false } }
        if let combo { return combo.caps.joined(separator: " ") }
        return "⌥ " + (layout?.labels[50] ?? "`")
    }
}

private struct ShortcutChoiceCard: View {
    let keys: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: keys)
                    .scaledFont(size: 24, weight: .bold)
                    .foregroundColor(STheme.textBright)
                    .padding(.bottom, 10)
                Text(title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? STheme.accentTint : STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? STheme.accent : STheme.border, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundColor(STheme.accent)
                        .padding(16)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A note set off by an accent bar on its left, for what a choice implies.
struct OnboardingCallout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .scaledFont(size: 14)
            .foregroundColor(STheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(STheme.fill)
            .overlay(alignment: .leading) {
                Rectangle().fill(STheme.accent).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

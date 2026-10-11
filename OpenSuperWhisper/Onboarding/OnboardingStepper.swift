import SwiftUI

enum OnboardingStep: Int, CaseIterable, Comparable {
    case shortcut, model, permissions, firstTry

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    var title: LocalizedStringKey {
        switch self {
        case .shortcut: return "Shortcut"
        case .model: return "Model"
        case .permissions: return "Permissions"
        case .firstTry: return "First try"
        }
    }

    var eyebrow: LocalizedStringKey {
        switch self {
        case .shortcut: return "01 / Your shortcut"
        case .model: return "02 / Speech recognition"
        case .permissions: return "03 / Permissions"
        case .firstTry: return "04 / First dictation"
        }
    }

    var headline: LocalizedStringKey {
        switch self {
        case .shortcut: return "One key. Your words."
        case .model: return "The right model to start with."
        case .permissions: return "Only the access it needs."
        case .firstTry: return "Let's try a sentence."
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .shortcut: return "Pick the gesture that feels natural."
        case .model: return "One download, then dictation runs on your Mac."
        case .permissions: return "Each permission has a reason. You stay in control."
        case .firstTry: return "Say whatever comes to mind."
        }
    }
}

/// The four steps in a row: the current one in the accent, the ones behind it checked. A step
/// is a button when it can be reached, so going back never loses a choice.
struct OnboardingStepper: View {
    let current: OnboardingStep
    let isReachable: (OnboardingStep) -> Bool
    let select: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                if step != .shortcut {
                    Rectangle()
                        .fill(step <= current ? STheme.accent.opacity(0.5) : STheme.border)
                        .frame(minWidth: 12, maxWidth: .infinity)
                        .frame(height: 1)
                }
                item(step)
            }
        }
    }

    private func item(_ step: OnboardingStep) -> some View {
        let isCurrent = step == current
        let isDone = step < current
        return Button { if !isCurrent { select(step) } } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? STheme.accent : isDone ? STheme.accentSoft : Color.clear)
                    Circle()
                        .strokeBorder(isCurrent || isDone ? Color.clear : STheme.controlBorder, lineWidth: 1)
                    if isDone {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 11, weight: .bold)
                            .foregroundColor(STheme.accent)
                    } else {
                        Text(verbatim: "\(step.rawValue + 1)")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundColor(isCurrent ? STheme.onAccent : STheme.hint)
                    }
                }
                .frame(width: 26, height: 26)
                Text(step.title)
                    .scaledFont(size: 14, weight: isCurrent ? .semibold : .medium)
                    .foregroundColor(isCurrent ? STheme.accent : isDone ? STheme.textSecondary : STheme.hint)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCurrent && !isReachable(step))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

import SwiftUI
import OpenSuperWhisperCore

/// What the status card at the bottom of the sidebar has to say, worst problem first.
enum ReadinessState: Equatable {
    case ready(model: String, onDevice: Bool, microphone: String)
    case loading(model: String)
    case microphoneDenied
    case accessibilityDenied
    case noModel
    case engineError(String)

    var isProblem: Bool {
        switch self {
        case .ready, .loading: return false
        default: return true
        }
    }

    static func resolve(micGranted: Bool, accessibilityGranted: Bool, model: DictationModelOption?,
                        isLoading: Bool, engineError: String?, microphone: String) -> ReadinessState {
        if !micGranted { return .microphoneDenied }
        if !accessibilityGranted { return .accessibilityDenied }
        if let engineError { return .engineError(engineError) }
        guard let model else { return .noModel }
        if isLoading { return .loading(model: model.displayName) }
        return .ready(model: model.displayName, onDevice: model.engine != "remote", microphone: microphone)
    }
}

/// The card at the bottom of the sidebar: ready or not, with which model and microphone. When
/// something blocks dictation it turns orange and names the fix (#117, #100).
struct StatusCard: View {
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject private var models = ModelSelectionStore.shared
    @ObservedObject private var transcription = TranscriptionService.shared
    @ObservedObject private var microphones = MicrophoneService.shared
    @ObservedObject private var navigation = AppNavigation.shared

    private var state: ReadinessState {
        ReadinessState.resolve(
            micGranted: permissions.isMicrophonePermissionGranted,
            accessibilityGranted: permissions.isAccessibilityPermissionGranted,
            model: models.active,
            isLoading: transcription.isLoading,
            engineError: transcription.engineError,
            microphone: microphones.getActiveMicrophone()?.name ?? String(localized: "System default"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isProblem ? STheme.warn : STheme.readyDot)
                    .frame(width: 7, height: 7)
                Text(headline)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(state.isProblem ? STheme.warn : STheme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(detail)
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.sSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(state.isProblem ? STheme.warnBg : STheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(state.isProblem ? STheme.warnBorder : STheme.border, lineWidth: 1))
    }

    private var headline: LocalizedStringKey {
        switch state {
        case .ready(_, let onDevice, _): return onDevice ? "Ready · on this Mac" : "Ready · on your server"
        case .loading: return "Loading the model…"
        case .microphoneDenied: return "Microphone not allowed"
        case .accessibilityDenied: return "Can't type into other apps"
        case .noModel: return "No model chosen"
        case .engineError: return "The model didn't load"
        }
    }

    private var detail: String {
        switch state {
        case .ready(let model, _, let microphone): return "\(model) · \(microphone)"
        case .loading(let model): return model
        case .microphoneDenied: return String(localized: "Allow it in System Settings to dictate.")
        case .accessibilityDenied: return String(localized: "Allow Accessibility so the text lands where you type.")
        case .noModel: return String(localized: "Pick one in Settings → Models.")
        case .engineError(let message): return message
        }
    }

    private var action: (title: LocalizedStringKey, run: () -> Void)? {
        switch state {
        case .microphoneDenied:
            return ("Open System Settings", { permissions.requestMicrophonePermissionOrOpenSystemPreferences() })
        case .accessibilityDenied:
            return ("Open System Settings", { permissions.openSystemPreferences(for: .accessibility) })
        case .noModel:
            return ("Choose a model", { navigation.openSettings(.models) })
        case .engineError:
            return ("Retry", { TranscriptionService.shared.reloadEngine() })
        case .ready, .loading:
            return nil
        }
    }
}

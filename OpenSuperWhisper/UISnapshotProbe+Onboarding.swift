#if DEBUG
import KeyboardShortcuts
import SwiftUI

/// Onboarding as each kind of Mac sees it, staged: which models are on disk, what Apple's
/// speech model offers and the permissions are all made up, so none of this Mac's is read.
@MainActor
extension UISnapshotProbe {
    static let onboardingScreens: [String: () -> AnyView] = [
        "onboarding-model-apple-speech": { onboarding(.model, appleSpeech: .installed) },
        "onboarding-model-apple-speech-system-download": { onboarding(.model, appleSpeech: .systemDownload) },
        "onboarding-model-apple-speech-large-text": {
            onboarding(.model, appleSpeech: .installed, textScale: TextScale.maximum)
        },
        "onboarding-model-no-apple-speech": { onboarding(.model, appleSpeech: .unavailable) },
        "onboarding-model-reinstall": { onboarding(.model, appleSpeech: .installed, downloadedUltra: true) },
        "onboarding-shortcut-custom": { onboarding(.shortcut, custom: controlOptionD) },
        "onboarding-shortcut-custom-modifier": { onboarding(.shortcut, custom: .modifier(.rightCommand)) },
        "onboarding-shortcut-custom-empty": { onboarding(.shortcut, choice: .custom) },
        "onboarding-shortcut-custom-mouse": { onboarding(.shortcut, custom: .mouse(.button4)) },
        "onboarding-shortcut-custom-chord": {
            onboarding(.shortcut, custom: ModifierChord([.command, .option]).map { .chord($0) })
        },
        "onboarding-shortcut-custom-combination-large-text": {
            onboarding(.shortcut, custom: controlOptionD, textScale: TextScale.maximum)
        },
        "onboarding-shortcut-custom-empty-large-text": {
            onboarding(.shortcut, choice: .custom, textScale: TextScale.maximum)
        },
        "onboarding-shortcut-custom-large-text": {
            onboarding(.shortcut, custom: .modifier(.rightCommand), textScale: TextScale.maximum)
        },
        "onboarding-words": { onboarding(.words, words: ["Figma", "Marie-Claire"]) },
        "onboarding-words-empty": { onboarding(.words) },
        "onboarding-words-large-text": {
            onboarding(.words, words: ["Figma", "Marie-Claire", "Villeurbanne", "Kubernetes"],
                       textScale: TextScale.maximum)
        },
        "onboarding-permissions-custom-modifier": { onboarding(.permissions, custom: .modifier(.rightCommand)) },
        "onboarding-first-try-keycaps": { onboarding(.firstTry, choice: .keyCombination) },
        "onboarding-first-try-keycaps-modifier": { onboarding(.firstTry, choice: .rightOption) },
        "onboarding-first-try-keycaps-custom": { onboarding(.firstTry, custom: controlOptionD) },
        "onboarding-first-try-keycaps-large-text": {
            onboarding(.firstTry, custom: controlOptionD, textScale: TextScale.maximum)
        },
    ]

    private static let controlOptionD = RecordingTrigger.keyCombo(.init(.d, modifiers: [.control, .option]))

    private static func onboarding(_ step: OnboardingStep, appleSpeech: AppleSpeechOffer = .unavailable,
                                   downloadedUltra: Bool = false,
                                   choice: OnboardingShortcutOption = .keyCombination,
                                   custom: RecordingTrigger? = nil,
                                   words: [String] = [],
                                   textScale: Double = TextScale.default) -> AnyView {
        PermissionsManager.snapshotGrantsAll = true
        // A fresh install's list, whatever the previous screen of the run recorded.
        let fresh = KeyboardShortcuts.Name.toggleRecord.initialShortcut.map { RecordingTrigger.keyCombo($0) }
        AppPreferences.shared.recordingTriggers = RecordingTriggerSet(triggers: fresh.map { [$0] } ?? []).json
        AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
        let language = ProcessInfo.processInfo.environment["OSW_SNAPSHOT_LOCALE"] ?? "en"
        let system = OnboardingSystem.staged(
            downloaded: { type in
                if case .parakeet("ultra") = type { return downloadedUltra }
                return false
            },
            appleSpeech: { _ in appleSpeech },
            appLanguage: language,
            fullUserName: "Maxim Costa")
        let viewModel = OnboardingViewModel(system: system)
        viewModel.selectedShortcut = choice
        if let custom { viewModel.customTrigger = custom }
        viewModel.words = words
        return AnyView(OnboardingView(initialStep: step, viewModel: viewModel)
            .environmentObject(AppState())
            .environment(\.appTextScale, textScale))
    }
}
#endif

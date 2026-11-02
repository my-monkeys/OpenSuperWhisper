//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import CoreGraphics
import SwiftUI
import OpenSuperWhisperCore

/// First launch, shown full window in place of the app: shortcut, model, the user's words,
/// permissions, then a first dictation. Only the model is required, so nobody reaches the app
/// with no way to transcribe; the words are optional and permissions can be granted later, the
/// main window's status card asks for them.
struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @StateObject private var permissions = PermissionsManager()
    @EnvironmentObject private var appState: AppState
    @State private var step: OnboardingStep
    /// The furthest step visited, so the stepper can go forward again after going back.
    @State private var furthest: OnboardingStep
    @State private var inputMonitoringGranted = Self.readInputMonitoring()
    @Environment(\.locale) private var locale

    private let keyboardLayoutInfo: KeyboardLayoutInfo? = KeyboardLayoutProvider.shared.resolveInfo()
    /// PermissionsManager polls the microphone and Accessibility; Input Monitoring has no
    /// notification either, so it is re-read on the same rhythm while its row is on screen.
    private let inputMonitoringPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// `viewModel` is for the snapshot probe, which stages what this Mac has.
    init(initialStep: OnboardingStep = .shortcut, viewModel: OnboardingViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? OnboardingViewModel())
        _step = State(initialValue: initialStep)
        _furthest = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OnboardingStepper(current: step, isReachable: isReachable) { step = $0 }
                .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 16)
            hairline
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    stepHeading
                    stepContent
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            hairline
            footer
        }
        .background(STheme.windowBg.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .tint(STheme.accent)
        .onChange(of: step) { oldStep, newStep in
            viewModel.stepDidChange(from: oldStep)
            furthest = max(furthest, newStep)
        }
        // Covers the window being closed too, which no button of the view sees. Quitting skips
        // it on purpose: onboarding runs again on the next launch.
        .onDisappear { viewModel.onboardingWillClose() }
        .onReceive(inputMonitoringPoll) { _ in
            guard step == .permissions else { return }
            inputMonitoringGranted = Self.readInputMonitoring()
        }
    }

    // MARK: Frame

    private var header: some View {
        HStack(spacing: 16) {
            OnboardingBrand()
            Spacer(minLength: 0)
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
        }
        // Clears the traffic lights: the title bar is hidden and the view runs under it.
        .padding(.horizontal, 32).padding(.top, 44)
    }

    private var hairline: some View {
        Rectangle().fill(STheme.border).frame(height: 1)
    }

    private var stepHeading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.eyebrow)
                .scaledFont(size: 12, weight: .bold)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundColor(STheme.accent)
            Text(step.headline)
                .scaledFont(size: 30, weight: .bold)
                .foregroundColor(STheme.textBright)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .scaledFont(size: 16)
                .foregroundColor(STheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The model step promises one download, which Apple's model, preselected when offered,
    /// does not need.
    private var subtitle: LocalizedStringKey {
        if step == .model && viewModel.appleSpeechRow != nil {
            return "Built into macOS, or one download away. Either way, dictation runs on this Mac."
        }
        return step.subtitle
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .shortcut:
            OnboardingShortcutStep(viewModel: viewModel, layoutInfo: keyboardLayoutInfo)
        case .model:
            OnboardingModelStep(viewModel: viewModel)
        case .words:
            OnboardingWordsStep(viewModel: viewModel)
        case .permissions:
            OnboardingPermissionsStep(permissions: permissions,
                                      needsInputMonitoring: viewModel.needsInputMonitoring,
                                      triggerLabel: triggerCaps.joined(separator: " "),
                                      inputMonitoringGranted: inputMonitoringGranted,
                                      allGranted: permissionsGranted)
        case .firstTry:
            OnboardingFirstTryStep(triggerCaps: triggerCaps,
                                   microphoneGranted: permissions.isMicrophonePermissionGranted)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if showsFinishLater {
                Button("Finish later", action: finish)
                    .buttonStyle(OnboardingTextButtonStyle())
                    .help("Open the app now. You can finish the setup from Settings.")
            }
            Spacer(minLength: 0)
            if let previous = step.previous {
                Button("Back") { step = previous }
                    .buttonStyle(.sSecondary)
            }
            primaryButton
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .firstTry:
            Button("Skip", action: finish)
                .buttonStyle(.sSecondary)
            Button("Finish", action: finish)
                .buttonStyle(.sPrimary)
        case .words:
            Button("Skip") { if let next = step.next { step = next } }
                .buttonStyle(.sSecondary)
            continueButton(Text("Continue"))
        case .permissions where !permissionsGranted:
            continueButton(Text("Continue without"))
        default:
            continueButton(Text("Continue"))
        }
    }

    private func continueButton(_ label: Text) -> some View {
        Button {
            if step == .words { viewModel.commitWords() }
            if let next = step.next { step = next }
        } label: {
            HStack(spacing: 6) {
                label
                Image(systemName: "arrow.right")
                    .scaledFont(size: 12, weight: .bold)
            }
        }
        .buttonStyle(.sPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!isPassable(step))
    }

    // MARK: Rules

    /// Whether a step lets the user past it. Only the model gates: it is what the app needs to
    /// work at all. The test target is optional, and so are permissions, which can be granted
    /// later from the main window.
    private func isPassable(_ step: OnboardingStep) -> Bool {
        switch step {
        case .model: return viewModel.canContinue && !viewModel.isDownloading
        case .shortcut, .words, .permissions, .firstTry: return true
        }
    }

    /// Back is always open; forward only to a step already seen, past steps that are done.
    private func isReachable(_ target: OnboardingStep) -> Bool {
        target <= furthest && OnboardingStep.allCases.filter { $0 < target }.allSatisfy(isPassable)
    }

    /// Leaving early keeps the model requirement: hidden until a model is ready (or a remote
    /// server is chosen), and on the last step, where Skip does the same.
    private var showsFinishLater: Bool {
        step != .firstTry && isPassable(.model)
    }

    private var permissionsGranted: Bool {
        permissions.isMicrophonePermissionGranted && permissions.isAccessibilityPermissionGranted
            && (!viewModel.needsInputMonitoring || inputMonitoringGranted)
    }

    private var triggerCaps: [String] {
        if let trigger = viewModel.effectiveTrigger, trigger != viewModel.combination {
            return OnboardingShortcutLabel.caps(for: trigger, locale: locale)
        }
        return OnboardingShortcutLabel.combinationCaps(viewModel.combination, layout: keyboardLayoutInfo,
                                                       locale: locale)
    }

    private static func readInputMonitoring() -> Bool {
        #if DEBUG
        // The snapshot probe's staged permissions: nothing of this Mac's is read.
        if PermissionsManager.snapshotGrantsAll { return true }
        #endif
        return CGPreflightListenEventAccess()
    }

    private func finish() {
        viewModel.onboardingWillClose()
        appState.hasCompletedOnboarding = true
    }
}

/// The app's mark in the top-left corner, as the sidebar draws it once setup is done.
private struct OnboardingBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: -1) {
                Text(verbatim: "OpenSuper")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textBright)
                Text(verbatim: "Whisper")
                    .scaledFont(size: 17, weight: .bold)
                    .foregroundColor(STheme.textBright)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "OpenSuperWhisper"))
    }
}

/// A borderless text button, for the footer's way out.
struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(size: 14, weight: .semibold)
            .foregroundColor(configuration.isPressed ? STheme.hint : STheme.textBright)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
    }
}

#Preview {
    let _ = AppCore.install()
    OnboardingView()
}

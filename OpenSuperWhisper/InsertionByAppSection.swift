import SwiftUI

/// Per-app choice of how a transcription is put into the app you dictated into.
///
/// Typing and pasting fail in opposite places and a single global switch cannot serve both.
/// Typing posts a keyboard event per twenty characters, and an app that redraws its whole input
/// area on every keystroke falls behind: the text arrives cut off at a chunk boundary, or arrives
/// whole at a caret that has moved (#85). Pasting sends one event and is immune, but it needs the
/// clipboard, and someone who keeps things there on purpose is worse off with it.
///
/// A list rather than a built-in check on terminals, because the two reports we have are a
/// terminal and a text editor, and we only know about those two because two people looked closely
/// at text they had just dictated. Anyone else can now fix their own app without filing a report
/// that is hard to place.
struct InsertionByAppSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var showingAppPicker = false
    @State private var pickerTargetID: UUID?

    var body: some View {
        SSection(title: "Insertion by app") {
            SRow(title: "Typing pace",
                 hint: "Milliseconds between keystroke bursts. Raise it if dictating into a busy input box duplicates or misplaces text; the cost is a slower insertion.") {
                HStack(spacing: 6) {
                    Stepper(value: $viewModel.typingPaceMilliseconds,
                            in: 0...TextInserter.maxChunkPauseMilliseconds) {
                        Text("\(viewModel.typingPaceMilliseconds) ms")
                            .scaledFont(size: 12)
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Apps listed here ignore the global “Paste instead of typing” switch.")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)

                if viewModel.appInsertionRules.isEmpty {
                    Text("No apps yet. Add one below.")
                        .scaledFont(size: 11)
                        .foregroundColor(STheme.hint)
                        .padding(.vertical, 4)
                }

                ForEach($viewModel.appInsertionRules) { $rule in
                    ruleRow($rule)
                }

                Button {
                    pickerTargetID = nil
                    showingAppPicker = true
                } label: {
                    Label("Add App", systemImage: "plus")
                        .scaledFont(size: 11.5, weight: .medium)
                }
                .controlSize(.small)
            }
            .padding(.leading, 16)
        }
        .sheet(isPresented: $showingAppPicker) {
            AppPickerSheet { applyPickedApp($0) }
        }
    }

    @ViewBuilder private func ruleRow(_ rule: Binding<AppInsertionRule>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    pickerTargetID = rule.wrappedValue.id
                    showingAppPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: InstalledApps.icon(
                            forBundleIdentifier: rule.wrappedValue.bundleIdentifier))
                            .resizable()
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.wrappedValue.appName.isEmpty
                                 ? "Choose an app…" : rule.wrappedValue.appName)
                                .scaledFont(size: 12)
                                .foregroundColor(rule.wrappedValue.appName.isEmpty
                                                 ? STheme.hint : STheme.text)
                            if !rule.wrappedValue.bundleIdentifier.isEmpty {
                                Text(rule.wrappedValue.bundleIdentifier)
                                    .scaledFont(size: 10)
                                    .foregroundColor(STheme.hint)
                            }
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .scaledFont(size: 9)
                            .foregroundColor(STheme.hint)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change the app")

                Picker("", selection: rule.mode) {
                    ForEach(AppInsertionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
                .help(rule.wrappedValue.mode.subtitle)

                Button {
                    let id = rule.wrappedValue.id
                    viewModel.appInsertionRules.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                        .scaledFont(size: 11)
                        .foregroundColor(STheme.hint)
                }
                .buttonStyle(.plain)
                .help("Remove this app")
                .frame(width: 24)
            }

            // Only typing has a pace to set, and only here is it worth setting: the global dial
            // slows every app, and the apps that need it are the exception.
            if rule.wrappedValue.mode == .type {
                HStack(spacing: 8) {
                    Toggle("Custom pace", isOn: Binding(
                        get: { rule.wrappedValue.typingPaceMilliseconds != nil },
                        set: { on in
                            rule.wrappedValue.typingPaceMilliseconds =
                                on ? viewModel.typingPaceMilliseconds : nil
                        }))
                        .scaledFont(size: 11)
                        .toggleStyle(.checkbox)

                    if let pace = rule.wrappedValue.typingPaceMilliseconds {
                        Stepper(value: Binding(
                            get: { pace },
                            set: { rule.wrappedValue.typingPaceMilliseconds = $0 }),
                                in: 0...TextInserter.maxChunkPauseMilliseconds) {
                            Text("\(pace) ms")
                                .scaledFont(size: 11)
                                .monospacedDigit()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.bottom, 2)
    }

    /// Reassigns the app on the targeted rule, or appends a new one.
    ///
    /// A new rule starts on Paste, because that is the mode that fixes the reported problem
    /// outright. Someone who cannot spare the clipboard switches it to Type and raises the pace,
    /// which is the reason both controls are here.
    private func applyPickedApp(_ app: InstalledApp) {
        if let targetID = pickerTargetID,
           let index = viewModel.appInsertionRules.firstIndex(where: { $0.id == targetID }) {
            viewModel.appInsertionRules[index].appName = app.name
            viewModel.appInsertionRules[index].bundleIdentifier = app.bundleIdentifier
        } else {
            viewModel.appInsertionRules.append(
                AppInsertionRule(bundleIdentifier: app.bundleIdentifier,
                                 appName: app.name,
                                 mode: .paste))
        }
        pickerTargetID = nil
    }
}

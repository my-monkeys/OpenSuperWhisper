import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhisperCore

/// Settings → App Context. One place to manage context-aware model selection:
/// the switching mode plus a list of every app/site → model rule, with inline
/// model pickers and add/remove controls. Rules are also created from the
/// menu-bar "Model" submenu; this tab shows and edits the same store.
struct AppContextSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var rules: [AppContextRuleRow] = []
    @State private var selectedID: String?
    /// All usable models right now, across engines — recomputed on appear and
    /// after edits. Context-aware selection only makes sense with 2+.
    @State private var availableModels: [DictationModelOption] = []

    private var hasChoice: Bool { availableModels.count > 1 }

    var body: some View {
        SPane(title: "Rules", subtitle: "Pick a model per app or site") {
            if hasChoice {
                SSection(title: "Behavior") {
                    HStack(spacing: 5) {
                        Text("When the front app changes")
                            .font(.system(size: 13)).foregroundColor(STheme.text)
                        InfoButton(text: "Bind a transcription model to an app (or a website, in supported browsers) so it switches automatically when you dictate there. Add a rule below (＋), or from the menu-bar “Model” submenu while that app is focused.\n\n• Ask on change — auto-switch by app, and ask the scope (System Default / this app / just once / forget) whenever you pick a model in the menu.\n• Auto · no prompt — auto-switch by app, but picking a model just sets the system default (no prompt). Set rules up in “Ask”, then switch here.\n• Off — no auto-switch and no prompts.")
                        Spacer()
                        Picker("", selection: $viewModel.contextAwareModelMode) {
                            ForEach(ContextAwareModelMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .frame(minHeight: 26)
                }

                SSection(title: "App & site rules") {
                    VStack(spacing: 0) {
                        if rules.isEmpty {
                            (Text("No rules yet.\n").foregroundColor(STheme.hint)
                                + Text("Click ＋ to add an app, or bind a model from the menu-bar “Model” submenu while an app is focused.")
                                    .foregroundColor(STheme.hint.opacity(0.75)))
                                .font(.system(size: 11.5))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28).padding(.horizontal, 16)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(rules) { rule in
                                        ruleRow(rule)
                                        if rule.id != rules.last?.id {
                                            Rectangle().fill(STheme.border).frame(height: 1)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 120, maxHeight: 280)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                    HStack(spacing: 8) {
                        Button(action: addApp) {
                            Image(systemName: "plus").frame(width: 22, height: 16)
                        }
                        .controlSize(.small)
                        .help("Add an application…")
                        Button(action: removeSelected) {
                            Image(systemName: "minus").frame(width: 22, height: 16)
                        }
                        .controlSize(.small)
                        .disabled(selectedID == nil)
                        .help("Remove the selected rule")
                        Spacer()
                    }
                }
            } else {
                SWarnBox {
                    Text("**Rules need at least two models to switch between.**")
                    Text("Context-aware selection switches the transcription model based on the app (or website) you're dictating in — download another model in Models to get started.")
                        .foregroundColor(STheme.text)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AppContextModelRules.didChangeNotification)) { _ in
            reload()
        }
    }

    private func ruleRow(_ rule: AppContextRuleRow) -> some View {
        let isSelected = rule.id == selectedID
        return HStack(spacing: 10) {
            Group {
                if let icon = rule.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable()
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let host = rule.host {
                    Text(host)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { rule.model },
                set: { newModel in
                    AppContextModelRules.set(newModel, for: rule.bundleID, host: rule.host)
                    reload()
                }
            )) {
                ForEach(modelOptions(including: rule.model), id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = rule.id }
    }

    // MARK: - Data

    private func reload() {
        availableModels = ModelCatalog.allAvailable()
        rules = AppContextRuleRow.loadAll()
        if let sel = selectedID, !rules.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
    }

    /// Models offered in a row's picker: everything usable now, plus the rule's
    /// current model if it isn't currently available (so the choice is never lost).
    private func modelOptions(including current: DictationModelOption) -> [DictationModelOption] {
        var options = availableModels
        if !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        // Default the new rule to whatever model is currently in effect.
        guard let defaultModel = ModelCatalog.activeOption() ?? availableModels.first else { return }
        AppContextModelRules.set(defaultModel, for: bundleID)
        reload()
        selectedID = bundleID
    }

    private func removeSelected() {
        guard let id = selectedID, let rule = rules.first(where: { $0.id == id }) else { return }
        AppContextModelRules.remove(bundleID: rule.bundleID, host: rule.host)
        selectedID = nil
        reload()
    }
}

/// One displayable app/site rule, resolved from the persisted store.
struct AppContextRuleRow: Identifiable {
    /// Storage key: "bundleID" (app-wide) or "bundleID|host" (per-site).
    let id: String
    let bundleID: String
    let host: String?
    let model: DictationModelOption
    let appName: String
    let icon: NSImage?

    static func loadAll() -> [AppContextRuleRow] {
        AppContextModelRules.all().map { key, model -> AppContextRuleRow in
            let (bundleID, host) = parse(key)
            let (name, icon) = appInfo(for: bundleID)
            return AppContextRuleRow(id: key, bundleID: bundleID, host: host,
                                     model: model, appName: name, icon: icon)
        }
        .sorted {
            if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                return ($0.host ?? "") < ($1.host ?? "")
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    static func parse(_ key: String) -> (bundleID: String, host: String?) {
        if let pipe = key.firstIndex(of: "|") {
            return (String(key[..<pipe]), String(key[key.index(after: pipe)...]))
        }
        return (key, nil)
    }

    /// Resolve an installed app's display name + icon; fall back to the bundle id
    /// (with a generic icon) when the app isn't installed any more.
    private static func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
}

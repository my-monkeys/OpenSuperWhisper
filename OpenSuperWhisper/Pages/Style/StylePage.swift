import SwiftUI
import OpenSuperWhisperCore

/// How text is formatted: the three styles (not built yet) and everything set per app, merged
/// from what used to be Settings → Rules and Output → Insertion by app.
struct StylePage: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var modelRules: [String: DictationModelOption] = [:]
    @State private var availableModels: [DictationModelOption] = []
    /// Apps just picked that nothing is set for yet. Kept only while the page is open: a row
    /// with no setting behind it has nothing to persist.
    @State private var pendingApps: [InstalledApp] = []
    @State private var expandedID: String?
    @State private var picker: PickerPurpose?
    @State private var pendingRemoval: PerAppEntry?

    #if DEBUG
    /// Lets the snapshot renderer show the first row open.
    static var snapshotExpandsFirstRow = false
    #endif

    private enum PickerPurpose: Identifiable {
        case add
        case reassign(PerAppEntry)
        var id: String {
            switch self {
            case .add: return "add"
            case .reassign(let entry): return "reassign-\(entry.id)"
            }
        }
    }

    private var entries: [PerAppEntry] {
        PerAppEntries.build(insertionRules: viewModel.appInsertionRules,
                            profiles: viewModel.appContextProfiles,
                            modelRules: modelRules,
                            pending: pendingApps)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Style", subtitle: "How your text is formatted. Pick a style, then say where it applies.")
                StyleCards()
                StyleRulesGroup(viewModel: viewModel, hasModelChoice: availableModels.count > 1)
                VStack(alignment: .leading, spacing: 12) {
                    perAppHeader
                    perAppList
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AppContextModelRules.didChangeNotification)) { _ in
            reload()
        }
        .sheet(item: $picker) { purpose in
            AppPickerSheet { app in picked(app, for: purpose) }
        }
        .alert(removalTitle, isPresented: Binding(get: { pendingRemoval != nil },
                                                  set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { entry in
            Button("Remove", role: .destructive) { remove(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.isSite
                 ? "The model chosen for this site is forgotten."
                 : "Its insertion mode, model and formatting instructions are removed.")
        }
    }

    private var perAppHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Per app")
                .scaledFont(size: 19, weight: .bold)
                .foregroundColor(STheme.textBright)
            InfoButton(text: "Insertion, model and formatting for one app, on one line. Apps with an insertion mode ignore the global “Paste instead of typing” switch.\n\nSite rules pick a model for one website in Safari, Arc and other supported browsers. Create them from the menu-bar “Model” submenu while the site is open.")
            Spacer(minLength: 0)
            Button {
                picker = .add
            } label: {
                Label("Add an app", systemImage: "plus")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var perAppList: some View {
        let rows = entries
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No app has its own settings yet. Add one, or bind a model from the menu-bar “Model” submenu while an app is in front.")
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 24)
            }
            ForEach(rows) { entry in
                PerAppRow(entry: entry, viewModel: viewModel, models: availableModels,
                          expanded: expandedID == entry.id,
                          onToggle: { toggle(entry) },
                          onRemove: { pendingRemoval = entry },
                          onChangeApp: { picker = .reassign(entry) })
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: expandedID)
    }

    private var removalTitle: LocalizedStringKey {
        guard let entry = pendingRemoval else { return "" }
        return "Remove \(entry.title) from every rule?"
    }

    // MARK: - Actions

    private func reload() {
        availableModels = ModelCatalog.allAvailable()
        modelRules = AppContextModelRules.all()
        #if DEBUG
        if Self.snapshotExpandsFirstRow, expandedID == nil {
            expandedID = entries.first { !$0.isSite }?.id
        }
        #endif
    }

    private func toggle(_ entry: PerAppEntry) {
        expandedID = expandedID == entry.id ? nil : entry.id
    }

    private func picked(_ app: InstalledApp, for purpose: PickerPurpose) {
        let key = PerAppEntry.groupKey(app.bundleIdentifier)
        switch purpose {
        case .add:
            if !entries.contains(where: { $0.id == key }) {
                pendingApps.append(app)
            }
        case .reassign(let entry):
            PerAppStore(viewModel: viewModel).reassign(entry, to: app)
            pendingApps.removeAll { PerAppEntry.groupKey($0.bundleIdentifier) == PerAppEntry.groupKey(entry.bundleID) }
            reload()
        }
        expandedID = key
    }

    private func remove(_ entry: PerAppEntry) {
        PerAppStore(viewModel: viewModel).remove(entry)
        pendingApps.removeAll { PerAppEntry.groupKey($0.bundleIdentifier) == PerAppEntry.groupKey(entry.bundleID) }
        if expandedID == entry.id { expandedID = nil }
        pendingRemoval = nil
        reload()
    }
}

/// The three styles of the design. Not built yet: shown disabled, with the place today's AI
/// cleanup instruction is set.
private struct StyleCards: View {
    private struct Sample: Identifiable {
        let id: String
        let name: LocalizedStringKey
        let detail: LocalizedStringKey
        let example: LocalizedStringKey
    }

    private let samples = [
        Sample(id: "raw", name: "Raw", detail: "Exactly what you say, without the hesitations.",
               example: "um see you thursday for the demo"),
        Sample(id: "pro", name: "Pro", detail: "Full sentences, careful punctuation.",
               example: "See you Thursday for the demo?"),
        Sample(id: "personal", name: "Personal", detail: "Relaxed tone, short sentences.",
               example: "see you thursday for the demo?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(samples) { card($0) }
            }
            .disabled(true)
            .accessibilityElement(children: .contain)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SoonBadge()
                Text("Styles are coming. Today, AI cleanup uses the instruction set in Settings → Text & AI.")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Button("Open") { AppNavigation.shared.openSettings(.textAndAI) }
                    .buttonStyle(.plain)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.accent)
                    .fixedSize()
            }
        }
    }

    private func card(_ sample: Sample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sample.name)
                .scaledFont(size: 17, weight: .bold)
                .foregroundColor(STheme.textBright)
            Text(sample.detail)
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            Text(sample.example)
                .scaledFont(size: 14)
                .foregroundColor(STheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(STheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(STheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(STheme.border, lineWidth: 1))
        .opacity(0.6)
    }
}

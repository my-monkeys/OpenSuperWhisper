import SwiftUI
import OpenSuperWhisperCore

/// Everything set for one app: the writing rules AI cleanup follows there, the insertion mode and
/// the model. It was the lower half of the Style page until it got its own tab (#257), merged
/// from what used to be Settings → Rules and Output → Insertion by app.
struct PerAppPage: View {
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
                            styles: viewModel.appWritingStyles,
                            pending: pendingApps)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Per app",
                           subtitle: "Give an app its own profile: the writing rules AI cleanup follows there, and how the text is inserted.") {
                    Button {
                        picker = .add
                    } label: {
                        Label("Add an app", systemImage: "plus")
                    }
                    .buttonStyle(.sPrimary)
                }
                PerAppRulesGroup(viewModel: viewModel, hasModelChoice: availableModels.count > 1)
                perAppList
                Text("Site rules pick a model for one website in Safari, Arc and other supported browsers. Create them from the menu-bar “Model” submenu while the site is open.")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
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

import SwiftUI
import OpenSuperWhisperCore

/// One app (or site) in Style → Per app: what is customised on the left, the quick choices on
/// the right, and the full set of options under "›".
struct PerAppRow: View {
    let entry: PerAppEntry
    @ObservedObject var viewModel: SettingsViewModel
    /// Every model usable right now. The model menu only appears with two or more, as before.
    let models: [DictationModelOption]
    let expanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onChangeApp: () -> Void

    private static let insertionWidth: CGFloat = 150
    private static let modelWidth: CGFloat = 170

    private var store: PerAppStore { PerAppStore(viewModel: viewModel) }
    private var showsModelMenu: Bool { models.count > 1 && entry.hasBundle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    identity.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                    controls
                    chevron
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        identity.frame(maxWidth: .infinity, alignment: .leading)
                        chevron
                    }
                    HStack(spacing: 10) { controls }
                        .padding(.leading, 46)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if expanded {
                PerAppDetail(entry: entry, viewModel: viewModel, showsModelMenu: showsModelMenu,
                             onRemove: onRemove, onChangeApp: onChangeApp)
                    .padding(.leading, 46)
                    .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(entry.hasBundle ? STheme.textBright : STheme.hint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: summary)
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(entry.bundleID)
    }

    private var icon: some View {
        Image(nsImage: InstalledApps.icon(forBundleIdentifier: entry.bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: 30, height: 30)
            .frame(width: 34, height: 34)
            .overlay(alignment: .bottomTrailing) {
                if entry.isSite {
                    Image(systemName: "globe")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundColor(STheme.accent)
                        .padding(2)
                        .background(Circle().fill(STheme.cardBg))
                }
            }
    }

    @ViewBuilder private var controls: some View {
        StyleSoonPill()
        if !entry.isSite && entry.hasBundle {
            insertionMenu
        } else {
            Color.clear.frame(width: Self.insertionWidth, height: 1)
        }
        if showsModelMenu {
            modelMenu
        }
    }

    private var chevron: some View {
        Button(action: onToggle) {
            Image(systemName: "chevron.right")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(STheme.hint)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide details" : "Show details")
    }

    private var insertionMenu: some View {
        let selection = Binding<AppInsertionMode?>(
            get: { entry.insertion?.mode },
            set: { store.setInsertion($0, for: entry) })
        return RowMenu(label: Text(insertionLabel), width: Self.insertionWidth) {
            Picker("", selection: selection) {
                Text("Default insertion").tag(AppInsertionMode?.none)
                ForEach(AppInsertionMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(AppInsertionMode?.some(mode))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help(entry.insertion?.mode.subtitle ?? String(localized: "Follows the global “Paste instead of typing” switch"))
    }

    private var insertionLabel: LocalizedStringKey {
        guard let mode = entry.insertion?.mode else { return "Default insertion" }
        return LocalizedStringKey(mode.title)
    }

    private var modelMenu: some View {
        let selection = Binding<DictationModelOption?>(
            get: { entry.model },
            set: { store.setModel($0, for: entry) })
        var options = models
        // A rule's model stays listed even when it is not installed any more, so the choice is
        // never silently lost.
        if let current = entry.model, !options.contains(current) { options.insert(current, at: 0) }
        return RowMenu(label: entry.model.map { Text(verbatim: $0.displayName) } ?? Text("Default model"),
                       width: Self.modelWidth) {
            Picker("", selection: selection) {
                Text("Default model").tag(DictationModelOption?.none)
                ForEach(options, id: \.self) { model in
                    Text(verbatim: model.displayName).tag(DictationModelOption?.some(model))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help(entry.model?.displayName ?? String(localized: "Keeps the model in effect"))
    }

    /// What is customised for this row, in a line.
    private var summary: String {
        if entry.isSite {
            return String(localized: "Site · model only")
        }
        var parts: [String] = []
        if let rule = entry.insertion {
            switch rule.mode {
            case .paste: parts.append(String(localized: "Pastes"))
            case .type:
                if let pace = rule.typingPaceMilliseconds {
                    parts.append(String(localized: "Types, \(pace) ms"))
                } else {
                    parts.append(String(localized: "Types"))
                }
            }
        }
        if entry.profiles.contains(where: { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            parts.append(String(localized: "Formatting instructions"))
        }
        if let model = entry.model, !showsModelMenu {
            parts.append(String(localized: "Model: \(model.displayName)"))
        }
        if parts.isEmpty {
            return String(localized: "Nothing customised yet")
        }
        return parts.joined(separator: " · ")
    }
}

/// A bordered "Value ▾" menu of a fixed width, so the columns line up from row to row and a long
/// model name truncates in the middle instead of widening its row.
private struct RowMenu<Content: View>: View {
    let label: Text
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                label
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundColor(STheme.hint)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The per-app style column, drawn but not built yet.
private struct StyleSoonPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Style")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.hint)
            SoonBadge()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.controlBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
        .opacity(0.7)
        .fixedSize()
        .help("Styles per app are coming")
        .accessibilityLabel(Text("Style per app, coming soon"))
    }
}

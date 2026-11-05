import SwiftUI
import OpenSuperWhisperCore

/// One app (or site) in the Per app page: its icon and name, a badge for each thing that is not
/// default, the on/off switch, and the editor under "›" where the choices are made.
struct PerAppRow: View {
    let entry: PerAppEntry
    @ObservedObject var viewModel: SettingsViewModel
    /// Every model usable right now. The model menu only appears with two or more.
    let models: [DictationModelOption]
    let expanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onChangeApp: () -> Void
    let onAddSite: (String) -> Void

    private var store: PerAppStore { PerAppStore(viewModel: viewModel) }
    private var showsModelMenu: Bool { models.count > 1 && entry.hasBundle }
    private var isOn: Bool { PerAppSwitch.isOn(entry.bundleID, disabled: viewModel.perAppDisabledBundleIDs) }
    /// A built-in profile for an app this Mac does not have: shown, greyed, with its bundled icon.
    private var isMissingBuiltIn: Bool {
        !entry.isSite && entry.hasBundle
            && !InstalledApps.isInstalled(bundleIdentifier: entry.bundleID)
            && InstalledApps.bundledIcon(forBundleIdentifier: entry.bundleID) != nil
    }
    private var styleName: String? {
        entry.style.map { WritingStyleText.name(WritingStyle.resolve($0, custom: viewModel.customWritingStyles)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    identity.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    badges
                    chevron
                }
                .opacity(isOn ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                if entry.hasBundle {
                    SSwitch(isOn: Binding(get: { isOn }, set: { store.setEnabled($0, for: entry) }))
                        .help(isOn ? "Switch off: none of this app's settings apply"
                                   : "Switch on: this app's settings apply again")
                }
            }
            .padding(.vertical, 10)

            if expanded {
                PerAppDetail(entry: entry, viewModel: viewModel, models: models,
                             showsModelMenu: showsModelMenu, isOn: isOn,
                             onRemove: onRemove, onChangeApp: onChangeApp,
                             onAddSite: onAddSite)
                    .padding(.leading, 46)
                    .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(entry.hasBundle && !isMissingBuiltIn ? STheme.textBright : STheme.hint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isMissingBuiltIn {
                    Text("Not installed")
                        .scaledFont(size: 11)
                        .foregroundColor(STheme.hint)
                }
            }
        }
        .help(entry.bundleID)
    }

    private var badges: some View {
        TrailingFlowLayout(spacing: 6, minimumWidth: 120) {
            ForEach(PerAppBadge.badges(for: entry, styleName: styleName), id: \.self) { badge in
                PerAppBadgeView(badge: badge)
            }
        }
    }

    private var icon: some View {
        Image(nsImage: InstalledApps.icon(forBundleIdentifier: entry.bundleID))
            .resizable()
            .interpolation(.high)
            .saturation(isMissingBuiltIn ? 0 : 1)
            .opacity(isMissingBuiltIn ? 0.55 : 1)
            .frame(width: 28, height: 28)
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
}

/// One small badge: a customised value, or the faint "Default" of a row with none.
private struct PerAppBadgeView: View {
    let badge: PerAppBadge

    var body: some View {
        switch badge {
        case .standard:
            Text("Default")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint.opacity(0.7))
        default:
            text
                .scaledFont(size: 12, weight: .medium)
                .foregroundColor(STheme.textBright)
                .lineLimit(1)
                .truncationMode(.middle)
                // A model's name can be as long as a file path; the badge shortens it rather than
                // widening the row.
                .frame(maxWidth: 200)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(STheme.controlBg))
                .overlay(Capsule().stroke(STheme.border, lineWidth: 1))
        }
    }

    private var text: Text {
        switch badge {
        case .style(let name): return Text(verbatim: name)
        case .cleanup(true): return Text("AI cleanup")
        case .cleanup(false): return Text("No AI cleanup")
        case .model(let name): return Text(verbatim: name)
        case .formatting: return Text("Formatting rules")
        case .insertion(.paste, _, _): return Text("Pastes")
        case .insertion(.type, let pace, let layoutID):
            let types = pace.map { Text("Types, \($0) ms") } ?? Text("Types")
            guard let layoutID else { return types }
            return types + Text(verbatim: " · \(RemoteKeyboardLayouts.name(id: layoutID) ?? layoutID)")
        case .standard: return Text("Default")
        }
    }
}

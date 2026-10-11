import SwiftUI
import OpenSuperWhisperCore

/// The main window's sidebar: the app's name, the everyday pages, then the downloads, the
/// readiness card, Settings and Help.
struct AppSidebar: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var availableUpdateTag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            brand
                .padding(.horizontal, 8)
                .padding(.bottom, 22)
            ForEach(AppPage.allCases) { page in
                pageRow(page)
            }
            Spacer(minLength: 12)
            DownloadsSidebarCard(viewModel: viewModel)
                .padding(.bottom, 8)
            StatusCard(permissions: permissions)
                .padding(.bottom, 10)
            footerRow(title: "Settings", symbol: "gearshape", shortcut: "⌘,") {
                navigation.openSettings(.dictation)
            }
            footerRow(title: "Help & what's new", symbol: "questionmark.circle", shortcut: nil,
                      dot: availableUpdateTag != nil) {
                navigation.closeSettings()
                navigation.helpOpen = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 44)
        .padding(.bottom, 16)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(STheme.sidebarBg.ignoresSafeArea())
        .task {
            if let releases = try? await UpdateChecker.fetchReleases() {
                availableUpdateTag = UpdateChecker.availableUpdate(in: releases)?.tagName
            }
        }
    }

    private var brand: some View {
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

    private func pageRow(_ page: AppPage) -> some View {
        let selected = navigation.page == page && navigation.settingsRubric == nil
        return Button {
            navigation.closeSettings()
            navigation.helpOpen = false
            navigation.go(page)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: page.symbol)
                    .scaledFont(size: 14, weight: .medium)
                    .frame(width: 20)
                    .foregroundColor(selected ? STheme.accent : STheme.hint)
                Text(page.title)
                    .scaledFont(size: 15, weight: selected ? .bold : .medium)
                    .foregroundColor(selected ? STheme.accent : page.isAvailable ? STheme.textSecondary : STheme.faint)
                Spacer(minLength: 0)
                if !page.isAvailable { SoonBadge() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? STheme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!page.isAvailable)
        .help(page.isAvailable ? Text("") : Text("Coming soon"))
    }

    private func footerRow(title: LocalizedStringKey, symbol: String, shortcut: String?, dot: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .scaledFont(size: 14)
                    .frame(width: 20)
                    .foregroundColor(STheme.hint)
                Text(title)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundColor(STheme.textSecondary)
                if dot {
                    Circle().fill(STheme.accent).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
                if let shortcut { ShortcutBadge(text: shortcut) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

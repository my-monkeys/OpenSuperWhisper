import SwiftUI
import OpenSuperWhisperCore

/// The "Value ▾" menus of an app, in the editor under its row: the writing style, the
/// insertion mode, the keyboard of a typed app and the model. The row itself only shows what they are set to, as badges.
struct PerAppPickers {
    let entry: PerAppEntry
    let viewModel: SettingsViewModel
    /// Every model usable right now.
    let models: [DictationModelOption]

    private static let width: CGFloat = 200

    private var store: PerAppStore { PerAppStore(viewModel: viewModel) }

    /// A site row has no style: like insertion, it follows the app.
    var styleMenu: some View {
        let selection = Binding<String?>(get: { entry.style }, set: { store.setStyle($0, for: entry) })
        let styles = WritingStyle.builtIns + viewModel.customWritingStyles
        let label = entry.style.map { WritingStyleText.name(WritingStyle.resolve($0, custom: viewModel.customWritingStyles)) }
        return RowMenu(label: label.map { Text(verbatim: $0) } ?? Text("Default style"), width: Self.width) {
            Picker("", selection: selection) {
                Text("Default style").tag(String?.none)
                ForEach(styles) { style in
                    Text(verbatim: WritingStyleText.name(style)).tag(String?.some(style.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    var insertionMenu: some View {
        let selection = Binding<AppInsertionMode?>(
            get: { entry.insertion?.mode },
            set: { store.setInsertion($0, for: entry) })
        let label = entry.insertion.map { Text(LocalizedStringKey($0.mode.title)) } ?? Text("Default insertion")
        return RowMenu(label: label, width: Self.width) {
            Picker("", selection: selection) {
                Text("Default insertion").tag(AppInsertionMode?.none)
                ForEach(AppInsertionMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(AppInsertionMode?.some(mode))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// The layout of the computer the app's text goes to. Labelled and listed the way the removed
    /// global setting was: this Mac's own first, then the installed layouts.
    var keyboardMenu: some View {
        let selection = Binding<String?>(
            get: { entry.insertion?.keyboardLayoutID },
            set: { store.setKeyboardLayout($0, for: entry) })
        let label = selection.wrappedValue.map { Text(verbatim: RemoteKeyboardLayouts.name(id: $0) ?? $0) }
            ?? Text("Same as this Mac")
        return RowMenu(label: label, width: Self.width) {
            Picker("", selection: selection) {
                Text("Same as this Mac").tag(String?.none)
                ForEach(RemoteKeyboardLayouts.choices()) { layout in
                    Text(verbatim: layout.name).tag(String?.some(layout.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    var modelMenu: some View {
        let selection = Binding<DictationModelOption?>(
            get: { entry.model },
            set: { store.setModel($0, for: entry) })
        var options = models
        // A rule's model stays listed even when it is not installed any more, so the choice is
        // never silently lost.
        if let current = entry.model, !options.contains(current) { options.insert(current, at: 0) }
        return RowMenu(label: entry.model.map { Text(verbatim: $0.displayName) } ?? Text("Default model"),
                       width: Self.width) {
            Picker("", selection: selection) {
                Text("Default model").tag(DictationModelOption?.none)
                ForEach(options, id: \.self) { model in
                    Text(verbatim: model.displayName).tag(DictationModelOption?.some(model))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// A bordered "Value ▾" menu of a fixed width, so the menus line up and a long model name
/// truncates in the middle instead of widening its row.
struct RowMenu<Content: View>: View {
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

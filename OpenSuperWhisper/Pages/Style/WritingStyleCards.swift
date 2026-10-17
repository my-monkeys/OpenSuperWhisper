import SwiftUI
import OpenSuperWhisperCore

/// The writing styles at the top of the Style page: pick the one AI cleanup uses by default, and
/// write your own (#160). An app can override the choice from its row below.
struct WritingStyleCards: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var editing: WritingStyle?

    private static let columns = [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)]

    private var styles: [WritingStyle] { WritingStyle.builtIns + viewModel.customWritingStyles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(styles) { card($0) }
                newStyleCard
            }
            footer
        }
        // The menu-bar Style submenu writes the preference directly.
        .onReceive(NotificationCenter.default.publisher(for: WritingStyle.didChangeNotification)) { _ in
            viewModel.writingStyleID = AppPreferences.shared.writingStyleID
        }
        .sheet(item: $editing) { style in
            WritingStyleEditor(style: style,
                               isNew: !viewModel.customWritingStyles.contains { $0.id == style.id },
                               onSave: save, onDelete: delete)
        }
    }

    // MARK: - Cards

    private func card(_ style: WritingStyle) -> some View {
        let selected = viewModel.writingStyleID == style.id
        return Button {
            viewModel.writingStyleID = style.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WritingStyleText.name(style))
                        .scaledFont(size: 17, weight: .bold)
                        .foregroundColor(STheme.textBright)
                    Spacer(minLength: 8)
                    if !style.isBuiltIn {
                        Button { editing = style } label: {
                            Image(systemName: "pencil")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(STheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit this style")
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 15)
                            .foregroundColor(STheme.accent)
                    }
                }
                Text(WritingStyleText.detail(style))
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let example = WritingStyleText.example(style) {
                    Text(example)
                        .scaledFont(size: 14)
                        .foregroundColor(STheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(STheme.inputBg))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(STheme.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? STheme.accent : STheme.border, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var newStyleCard: some View {
        Button {
            editing = WritingStyle(name: "", instructions: "")
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .scaledFont(size: 17, weight: .semibold)
                Text("New style")
                    .scaledFont(size: 14, weight: .semibold)
            }
            .foregroundColor(STheme.accent)
            .frame(maxWidth: .infinity, minHeight: 110)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(STheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var footer: some View {
        if viewModel.aiPostProcessingEnabled {
            Text("Styles shape AI cleanup. An app can have its own style in its row below. Pro, Personal and your own styles follow their instructions best with Apple Intelligence or a 7B model.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SettingNotice("Styles shape AI cleanup, which is off. Raw stays as it is either way.") {
                Button("Turn on AI cleanup") { viewModel.aiPostProcessingEnabled = true }
                    .buttonStyle(.sPrimary)
            }
        }
    }

    // MARK: - Editing

    private func save(_ style: WritingStyle) {
        if let index = viewModel.customWritingStyles.firstIndex(where: { $0.id == style.id }) {
            viewModel.customWritingStyles[index] = style
        } else {
            viewModel.customWritingStyles.append(style)
            viewModel.writingStyleID = style.id
        }
        editing = nil
    }

    /// Apps that pointed at the style go back to the default rather than to a style id that no
    /// longer resolves.
    private func delete(_ style: WritingStyle) {
        viewModel.customWritingStyles.removeAll { $0.id == style.id }
        viewModel.appWritingStyles = viewModel.appWritingStyles.filter { $0.value != style.id }
        if viewModel.writingStyleID == style.id { viewModel.writingStyleID = WritingStyle.rawID }
        editing = nil
    }
}

extension WritingStyle {
    static let didChangeNotification = Notification.Name("WritingStyleDidChange")
}

/// The words shown for a style. Built-in styles are described here, in the UI language; a style
/// the user wrote shows its own name and the start of its instructions.
enum WritingStyleText {
    static func name(_ style: WritingStyle) -> String {
        switch style.id {
        case WritingStyle.rawID: return String(localized: "Raw")
        case WritingStyle.proID: return String(localized: "Pro")
        case WritingStyle.personalID: return String(localized: "Personal")
        default: return style.name.isEmpty ? String(localized: "Untitled style") : style.name
        }
    }

    static func detail(_ style: WritingStyle) -> String {
        switch style.id {
        case WritingStyle.rawID: return String(localized: "Your words, corrected. Nothing reworded.")
        case WritingStyle.proID: return String(localized: "Full sentences, careful punctuation.")
        case WritingStyle.personalID: return String(localized: "Relaxed tone, short sentences.")
        default: return style.instructions
        }
    }

    static func example(_ style: WritingStyle) -> String? {
        switch style.id {
        case WritingStyle.rawID: return String(localized: "So see you Thursday for the demo, right?")
        case WritingStyle.proID: return String(localized: "See you on Thursday for the demo.")
        case WritingStyle.personalID: return String(localized: "See you Thursday for the demo!")
        default: return nil
        }
    }
}

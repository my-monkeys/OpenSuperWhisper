import SwiftUI
import OpenSuperWhisperCore

/// One row per entry: the written form, the variants that reach it, its type and a menu.
struct DictionaryEntryList: View {
    let entries: [CustomDictionaryEntry]
    let dimmed: Bool
    let emptyMessage: LocalizedStringKey
    let onEdit: (CustomDictionaryEntry) -> Void
    let onDelete: (CustomDictionaryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text(emptyMessage)
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 28)
            }
            // Iterated by value: a binding into the array would resolve a deleted row.
            ForEach(entries) { entry in
                DictionaryEntryRow(entry: entry,
                                   onEdit: { onEdit(entry) },
                                   onDelete: { onDelete(entry) })
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }
}

private struct DictionaryEntryRow: View {
    let entry: CustomDictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(verbatim: title)
                .scaledFont(size: 15, weight: .bold,
                            design: entry.kind == .pattern ? .monospaced : .default)
                .foregroundColor(title.isEmpty ? STheme.hint : STheme.textBright)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            details
                .frame(maxWidth: .infinity, alignment: .leading)
            tag
            menu
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(hovering ? STheme.accentTint : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Edit"), onEdit)
    }

    /// A command is known by what you say ("new paragraph"), everything else by what it writes.
    private var title: String {
        entry.kind == .command ? (entry.triggers.first ?? "") : entry.trimmedReplacement
    }

    private var variants: [String] {
        switch entry.kind {
        case .word: return []
        case .command: return Array(entry.triggers.dropFirst())
        case .correction, .pattern: return entry.triggers
        }
    }

    private var details: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                Text(verbatim: variant)
                    .scaledFont(size: 13, design: entry.isRegex ? .monospaced : .default)
                    .foregroundColor(STheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(STheme.fill))
            }
            if entry.kind == .command {
                Text(verbatim: "→ \(visibleReplacement)")
                    .scaledFont(size: 13, design: .monospaced)
                    .foregroundColor(STheme.hint)
            }
        }
    }

    /// Line breaks drawn as the `\n` the user types for them.
    private var visibleReplacement: String {
        entry.trimmedReplacement.replacingOccurrences(of: "\n", with: "\\n")
    }

    private var tag: some View {
        Text(entry.kind.label)
            .scaledFont(size: 12, weight: .semibold)
            .foregroundColor(entry.kind.foreground)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(entry.kind.background))
            .fixedSize()
            .frame(minWidth: 104, alignment: .leading)
    }

    private var menu: some View {
        Menu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.hint)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

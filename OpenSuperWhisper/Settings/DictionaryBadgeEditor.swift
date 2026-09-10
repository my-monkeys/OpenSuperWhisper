import SwiftUI

/// The custom dictionary as a row of badges, one per result.
///
/// It used to be a two-column table, one line per phrasing. That forced anyone who says a thing
/// three ways to write the result three times, and once rules could hold several phrasings the
/// table had nowhere to put them. What the user cares about is the short list of results they
/// have taught it; the phrasings that reach each one are a detail behind it.
struct DictionaryBadgeEditor: View {
    @Binding var entries: [CustomDictionaryEntry]

    @State private var editing: UUID?

    var body: some View {
        FlowLayout(spacing: 6) {
            // Iterated by value, not with `ForEach($entries)`. A binding produced by a
            // collection resolves through the collection every time it is read, so deleting a
            // rule while its editor was still on screen left the open text field reading a row
            // that no longer existed, and the app trapped the moment the field lost focus.
            ForEach(entries) { entry in
                badge(for: entry)
            }
            addBadge
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
    }

    private func badge(for value: CustomDictionaryEntry) -> some View {
        let label = value.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = value.triggers.count

        return Button { editing = value.id } label: {
            HStack(spacing: 5) {
                Text(label.isEmpty ? "empty" : label)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(label.isEmpty ? STheme.hint : STheme.textBright)
                // Only worth showing when there is more than the obvious one behind it.
                if count > 1 {
                    Text("\(count)")
                        .scaledFont(size: 9, weight: .semibold)
                        .foregroundColor(STheme.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(STheme.accentSoft))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(STheme.controlBg))
            .overlay(Capsule().stroke(STheme.controlBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(value.triggers.joined(separator: ", "))
        .popover(isPresented: Binding(get: { editing == value.id },
                                      set: { if !$0 { editing = nil } }),
                 arrowEdge: .bottom) {
            DictionaryRuleEditor(
                initial: value,
                onChange: { updated in
                    guard let position = entries.firstIndex(where: { $0.id == updated.id })
                    else { return }
                    entries[position] = updated
                },
                onDelete: {
                    editing = nil
                    entries.removeAll { $0.id == value.id }
                })
        }
    }

    /// The rule being written, before it exists.
    ///
    /// Adding it up front and editing it in place meant anyone who opened the editor and thought
    /// better of it left an "empty" badge sitting in the row, which then has to be noticed and
    /// deleted. A rule now comes into being when it says something.
    @State private var pending: CustomDictionaryEntry?

    private var addBadge: some View {
        Button {
            pending = CustomDictionaryEntry()
        } label: {
            Image(systemName: "plus")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundColor(STheme.hint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().strokeBorder(STheme.controlBorder,
                                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                // The other badges are filled, so their whole capsule takes a click. This one is
                // only a dashed outline, and an outline is hit-tested along the line itself, which
                // left the inside of the capsule dead and forced people to hit the small glyph.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Add a rule")
        // `popover(item:)` rather than `isPresented` plus an `if let` inside. Wrapping the editor
        // in a conditional means clearing the state removes the content before the popover
        // dismisses it, and the editor's `onDisappear` never runs, so the rule it was holding is
        // silently dropped. Tested: a fully filled rule vanished on close. With `item:` the
        // editor is unconditional, exactly as it is for an existing badge, where saving has
        // always worked.
        .popover(item: $pending, arrowEdge: .bottom) { draft in
            DictionaryRuleEditor(
                initial: draft,
                onChange: { written in
                    // Fired as the editor goes away, so this is the finished rule rather than a
                    // keystroke. A rule that says nothing is one somebody started and thought
                    // better of, and it is not worth a badge.
                    guard !written.isBlank else { return }
                    entries.append(written)
                },
                onDelete: { pending = nil })
        }
    }
}

/// What sits behind one badge: the result on top, everything that reaches it underneath.
private struct DictionaryRuleEditor: View {
    let onChange: (CustomDictionaryEntry) -> Void
    let onDelete: () -> Void

    /// The rule being edited lives here rather than in the array behind it.
    ///
    /// Editing through a binding into the collection means every keystroke resolves the row out
    /// of that collection again, which works right up until the row is deleted while a field is
    /// still open. Editing a local copy and publishing it on change means the worst case is an
    /// editor working on a rule that no longer exists, instead of a trap.
    @State private var draft: CustomDictionaryEntry

    @FocusState private var focused: Int?

    init(initial: CustomDictionaryEntry,
         onChange: @escaping (CustomDictionaryEntry) -> Void,
         onDelete: @escaping () -> Void) {
        self.onChange = onChange
        self.onDelete = onDelete
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Writes")
                    .scaledFont(size: 9, weight: .bold)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(STheme.sectionTitle)

                TextField("", text: $draft.replacement, prompt: Text("GitHub"))
                    .textFieldStyle(.plain)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(STheme.textBright)
            }

            Divider().overlay(STheme.border)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(draft.isRegex ? "When it matches" : "When it hears")
                        .scaledFont(size: 9, weight: .bold)
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(STheme.sectionTitle)

                    Spacer()

                    Toggle("Regex", isOn: $draft.isRegex)
                        .toggleStyle(.checkbox)
                        .scaledFont(size: 10)
                        .foregroundColor(STheme.hint)
                        .help("Match with a regular expression and use $1, $2… in the result")
                }

                ForEach(Array(triggerBindings().enumerated()), id: \.offset) { position, binding in
                    HStack(spacing: 6) {
                        TextField("", text: binding,
                                  prompt: Text(draft.isRegex ? "([^.?!]+), said ([A-Z]\\w+)" : "git hub"))
                            .textFieldStyle(.plain)
                            .scaledFont(size: 12, design: draft.isRegex ? .monospaced : .default)
                            .focused($focused, equals: position)

                        Button { draft.removeTrigger(at: position) } label: {
                            Image(systemName: "minus.circle")
                                .scaledFont(size: 10)
                                .foregroundColor(STheme.hint)
                        }
                        .buttonStyle(.plain)
                        .disabled(position == 0 && draft.alternates.isEmpty)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(STheme.inputBg))
                }

                Button {
                    draft.alternates.append("")
                    focused = draft.triggers.count
                } label: {
                    Label(draft.isRegex ? "Another pattern" : "Another way of saying it", systemImage: "plus")
                        .scaledFont(size: 11)
                        .foregroundColor(STheme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            Divider().overlay(STheme.border)

            VStack(alignment: .leading, spacing: 5) {
                // A regex says for itself what it consumes, so the spacing choice would be a
                // second, contradictory answer to the same question.
                if !draft.isRegex {
                    Text("Spacing")
                        .scaledFont(size: 9, weight: .bold)
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(STheme.sectionTitle)

                    Picker("", selection: $draft.spacing) {
                        Text("Keep spaces").tag(CustomDictionaryEntry.Spacing.standalone)
                        Text("Opens").tag(CustomDictionaryEntry.Spacing.attachesRight)
                        Text("Closes").tag(CustomDictionaryEntry.Spacing.attachesLeft)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // The rule doing its job beats a description of what it does.
                Text(preview)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundColor(STheme.hint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider().overlay(STheme.border)

            Button(role: .destructive, action: onDelete) {
                Label("Delete this rule", systemImage: "trash")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.plain)
            .foregroundColor(STheme.hint)
        }
        .padding(14)
        // A floor, not a fixed size. The spacing picker is a segmented control carrying three
        // words, and its intrinsic width is more than 280 minus the padding: forced into a fixed
        // frame the content was centred and clipped at both edges, which is why the labels on the
        // left arrived cut in half.
        .frame(minWidth: 280)
        // Committed when the editor goes away, not per keystroke.
        //
        // Writing on every change fed a second update pass back into the badge row: the row
        // rebuilt, which re-declared this popover, which had SwiftUI re-present the NSPopover
        // mid-layout. That threw from AppKit while ordering the popover's window on screen.
        // Nothing behind the popover is visible while it is open, so there is nothing to gain
        // from updating it live, and the edit is not lost: it lands the moment the popover
        // closes, which is also when the badge becomes worth looking at again.
        .onDisappear { onChange(draft) }
    }

    /// A sentence the rule is likely to bite on, so the effect is visible rather than described.
    /// For a regex there is no way to build one from the pattern, so a fixed line of dialogue
    /// stands in: it is the case this was added for, and a pattern that does nothing to it
    /// shows that just as usefully.
    private static let regexSample = "Not tonight, said Frank."

    private var preview: String {
        guard !draft.isRegex else {
            return CustomDictionary.apply(Self.regexSample, entries: [draft])
        }
        let spoken = draft.triggers.first ?? "…"
        let sample: String
        switch draft.spacing {
        case .attachesRight: sample = "he said \(spoken) yes"
        case .attachesLeft: sample = "yes \(spoken) he said"
        case .standalone: sample = "yes \(spoken) no"
        }
        return CustomDictionary.apply(sample, entries: [draft])
    }

    /// The primary phrasing and its alternates edited as one list, since the distinction is an
    /// implementation detail the user has no reason to care about.
    private func triggerBindings() -> [Binding<String>] {
        [Binding(get: { draft.original }, set: { draft.original = $0 })]
            + draft.alternates.indices.map { index in
                Binding(get: { draft.alternates.indices.contains(index) ? draft.alternates[index] : "" },
                        set: { if draft.alternates.indices.contains(index) { draft.alternates[index] = $0 } })
            }
    }

}

/// Wraps its children onto as many lines as it needs. SwiftUI has no flow layout of its own.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty && x + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
                x = 0
            }
            row.indices.append(index)
            row.width = max(row.width, x + size.width)
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

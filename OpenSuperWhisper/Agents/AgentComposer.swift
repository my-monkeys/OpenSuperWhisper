import SwiftUI

/// The agent panel's reply box. One line, like a chat box: the microphone on the left (the main
/// action, so it is the filled one), the field, send on the right, which turns terracotta once
/// there is something to send. While a reply is dictated the microphone opens into delete,
/// recording and stop, and send stops the take and sends it.
struct AgentComposer: View {
    @ObservedObject var inbox: AgentInbox
    let request: AgentRequest
    /// The reply field takes the caret back when a take ends, so the user sees where the
    /// words went and can carry on typing.
    @FocusState private var replyFocused: Bool
    #if DEBUG
    /// Draws the focused look in the snapshot probe, whose window never becomes key.
    var showsFocus = false
    #endif

    private var listening: Bool { inbox.armedReplyID == request.id }
    private var draftText: String { inbox.drafts[request.id] ?? "" }
    private var hasDraft: Bool { !draftText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var isFocused: Bool {
        #if DEBUG
        if showsFocus { return true }
        #endif
        return replyFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            AgentShortcutHintsRow(hints: AgentShortcutHints.current(listening: listening))
                .padding(.leading, 6)
        }
        .onChange(of: listening) {
            guard !listening else { return }
            AgentPanelController.shared.focus()
            // The field is rebuilt as the bar unfolds; focus it once it is back.
            DispatchQueue.main.async { replyFocused = true }
        }
    }

    private var bar: some View {
        let ringed = isFocused && !hasDraft && !listening
        return HStack(alignment: .center, spacing: 8) {
            AgentRecordingControls(
                listening: listening,
                onDictate: { inbox.dictateReply(to: request) },
                onDelete: { inbox.discardDictation() },
                onStop: { inbox.stopDictating() })

            // While the microphone is open the bar folds to one line that says so, then
            // opens back onto the whole reply: a multi-line draft beside the controls made a
            // tall bar with most of its width doing nothing.
            if listening {
                Text(Self.listeningLabel(draft: draftText))
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                replyField
                    .transition(.opacity)
            }

            if listening {
                sendButton(fill: STheme.accent, tint: STheme.onAccent, help: "Stop and send") {
                    inbox.stopDictatingAndSend(request)
                }
            } else {
                sendButton(fill: hasDraft ? STheme.accent : STheme.fill,
                           tint: hasDraft ? STheme.onAccent : STheme.faint,
                           help: "Send (⏎)") { inbox.send(request) }
                    .disabled(!hasDraft)
            }
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Self.barRadius).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: Self.barRadius)
            .strokeBorder(borderColor, lineWidth: isFocused || listening ? 1.5 : 1))
        // An empty field with the caret in it glows, so it reads as waiting for words.
        .background(RoundedRectangle(cornerRadius: Self.barRadius + 3)
            .strokeBorder(STheme.accentSoft, lineWidth: 4)
            .padding(-3)
            .opacity(ringed ? 1 : 0))
        .animation(AgentRecordingControls.morph, value: listening)
        .animation(.easeOut(duration: 0.15), value: ringed)
    }

    private var borderColor: Color {
        if listening { return STheme.accent.opacity(0.7) }
        return isFocused ? STheme.accent : STheme.border
    }

    /// The field grows with its text up to `replyMaxHeight`, then scrolls, and always to its
    /// last line: a dictated reply lands at the end, and the field used to stay on the first
    /// lines, hiding the words just added.
    private var replyField: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TextField(placeholder, text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.textBright)
                    .padding(.vertical, 9)
                    .focused($replyFocused)
                    .id(Self.replyEnd)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: Self.replyMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: draftText) {
                proxy.scrollTo(Self.replyEnd, anchor: .bottom)
            }
        }
    }

    private var placeholder: String {
        switch request.kind {
        case .stop: return "Answer \(request.agent)"
        case .permission: return "Or say what to do instead"
        case .question: return "Or answer in your own words"
        }
    }

    private var draft: Binding<String> {
        let id = request.id
        return Binding(get: { inbox.drafts[id] ?? "" }, set: { inbox.drafts[id] = $0 })
    }

    private func sendButton(fill: Color, tint: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .scaledFont(size: 14, weight: .bold)
                .foregroundColor(tint)
                .frame(width: AgentRecordingControls.size, height: AgentRecordingControls.size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .help(help)
    }

    /// What the folded bar reads: that it is listening, and how the reply so far ends, so a
    /// second take that continues a first still has its context.
    static func listeningLabel(draft: String) -> String {
        let soFar = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return soFar.isEmpty ? "Listening…" : "Listening… after \u{201C}\(soFar)\u{201D}"
    }

    /// Past half the one-line bar's height, so it is clamped into a true pill there and stays a
    /// rounded box once the reply wraps.
    static let barRadius: CGFloat = 28

    static let replyEnd = "reply-end"
    /// About six lines of the reply's 14 pt text.
    static let replyMaxHeight: CGFloat = 120
}

/// The keys that work here, spelled the way the user set them up, as raised caps. The recording
/// trigger answers the agent once the panel has focus (a click in it is enough).
struct AgentShortcutHintsRow: View {
    let hints: [AgentShortcutHints]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(hints, id: \.action) { hint in
                HStack(spacing: 6) {
                    Text(hint.keys)
                        .scaledFont(size: 11.5, weight: .semibold)
                        .foregroundColor(STheme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(STheme.fill))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(STheme.border, lineWidth: 1))
                    Text(hint.action)
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                }
            }
        }
        .lineLimit(1)
    }
}

import AppKit
import KeyboardShortcuts
import LiquidGlass
import SwiftUI

/// A floating panel in the top-right corner, shown while an agent waits. It does not take focus
/// when it appears, so it never steals keystrokes from what the user is typing; clicking into
/// its reply field makes it key, like Spotlight.
@MainActor
final class AgentPanelController {
    static let shared = AgentPanelController()

    static let width: CGFloat = 560
    static let margin: CGFloat = 16

    private var panel: AgentPanel?

    /// The panel is the key window: the user clicked into it, so their trigger answers it.
    var hasFocus: Bool { panel?.isKeyWindow == true && panel?.isVisible == true }

    private var returnMonitor: Any?

    /// Return in the panel, handled here rather than by the field: a multi-line SwiftUI field
    /// takes Return for itself and never submits, so pressing it did nothing. Return sends,
    /// ⇧Return starts a new line. While a reply is dictated, Return stops and sends it, unless
    /// the user has a stop-and-submit binding of their own, which then does that job alone.
    private func watchReturnKey() {
        guard returnMonitor == nil else { return }
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return, keypad Enter
            guard isReturn, event.window is AgentPanel else { return event }
            // The field does not break the line on ⇧Return either, so the break is typed here,
            // at the caret, through the field's own text view.
            if event.modifierFlags.contains(.shift) {
                (event.window?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
            guard let request = AgentInbox.shared.current else { return event }
            let inbox = AgentInbox.shared
            if inbox.armedReplyID == request.id {
                guard AgentShortcutHints.submitKeys() == nil else { return event }
                inbox.stopDictatingAndSend(request)
            } else {
                inbox.send(request)
            }
            return nil
        }
    }

    /// Makes the panel key, so the reply field can take the caret.
    func focus() {
        panel?.makeKey()
    }

    private func stopWatchingReturnKey() {
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
        returnMonitor = nil
    }

    private init() {}

    func update(visible: Bool) {
        if visible {
            show()
            watchReturnKey()
        } else {
            hide()
            stopWatchingReturnKey()
        }
    }

    private func show() {
        if panel == nil {
            let panel = AgentPanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            let host = FirstClickHostingView(rootView: AgentPanelView(inbox: .shared))
            host.sizingOptions = [.preferredContentSize]
            panel.contentView = host
            // The card grows with the reply; keep its top edge where it was.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { _ in
                Task { @MainActor in AgentPanelController.shared.repin() }
            }
            self.panel = panel
        }
        guard let panel, !panel.isVisible else { return }
        place(panel)
        panel.orderFrontRegardless()
    }

    fileprivate func repin() {
        guard let panel, panel.isVisible else { return }
        place(panel)
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    /// Top-right of the screen with the menu bar, under it.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - Self.margin,
                                     y: visible.maxY - size.height - Self.margin))
    }
}

/// The panel opens without focus, and AppKit spends the first click on an unfocused window
/// making it key: the microphone looked as if it ignored the press. This lets that first
/// click reach the button too.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless panels refuse key status by default, which would leave the reply field unable to
/// take typing.
final class AgentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct AgentPanelView: View {
    @ObservedObject var inbox: AgentInbox
    /// The reply field takes the caret back when a take ends, so the user sees where the
    /// words went and can carry on typing.
    @FocusState private var replyFocused: Bool
    /// Which waiting agent is shown when several are; falls back to the oldest.

    /// Long replies scroll inside the card rather than growing it past most of the screen.
    private var maxMessageHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 900) * 0.55).rounded()
    }

    private var current: AgentRequest? {
        inbox.current
    }

    var body: some View {
        Group {
            if let request = current {
                card(for: request)
            }
        }
        .frame(width: AgentPanelController.width)
    }

    private func card(for request: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(for: request)
            ScrollView {
                content(for: request)
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: maxMessageHeight)
            .fixedSize(horizontal: false, vertical: true)
            composer(for: request)
            if request.kind != .stop { decisionRow(for: request) }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(10)  // room for the shadow inside the borderless panel
    }

    private func header(for request: AgentRequest) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AgentAvatar(kind: request.agentKind)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(STheme.textBright)
                    .lineLimit(1)
                // Redrawn every half minute so "2 minutes ago" keeps counting while it waits.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(subtitle(for: request, now: context.date))
                        .font(.system(size: 11.5))
                        .foregroundColor(STheme.hint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if inbox.pending.count > 1 { pager(for: request) }
            Button { inbox.dismiss(request) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(STheme.hint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(STheme.controlBg.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .pointerCursorOnHover()
            .help("Let it stop: the agent waits in its terminal, as it would without OpenSuperWhisper")
        }
    }

    @ViewBuilder private func content(for request: AgentRequest) -> some View {
        switch request.kind {
        case .stop:
            MarkdownView(markdown: request.message.isEmpty ? "_No message._" : request.message)
        case .permission:
            permissionContent(for: request)
        case .question:
            questionContent(for: request)
        }
    }

    private func permissionContent(for request: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wants to use **\(request.tool ?? "a tool")**")
                .font(.system(size: 13.5))
                .foregroundColor(STheme.text)
            if !request.message.isEmpty {
                Text(request.message)
                    .font(.system(size: 12.5))
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = request.toolDetail, !detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(STheme.textBright)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(STheme.inputBg.opacity(0.7)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionContent(for request: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array((request.questions ?? []).enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(STheme.accent)
                    }
                    Text(MarkdownView.inline(question.question))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(STheme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options, id: \.label) { option in
                        optionRow(option, question: question, request: request)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionRow(_ option: AgentQuestion.Option, question: AgentQuestion,
                           request: AgentRequest) -> some View {
        let picked = inbox.isPicked(option.label, in: question, of: request)
        return Button { inbox.toggle(option.label, in: question, of: request) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked
                      ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 14))
                    .foregroundColor(picked ? STheme.accent : STheme.hint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(STheme.textBright)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundColor(STheme.hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(picked ? STheme.accentSoft : STheme.inputBg.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(picked ? STheme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// The choice itself, for the kinds that are one: allow or deny, submit the answers.
    @ViewBuilder private func decisionRow(for request: AgentRequest) -> some View {
        HStack(spacing: 10) {
            Spacer()
            switch request.kind {
            case .permission:
                decisionButton("Deny", prominent: false) { inbox.deny(request) }
                decisionButton("Allow", prominent: true) { inbox.allow(request) }
            case .question:
                decisionButton("Answer", prominent: true, disabled: !inbox.canSubmitAnswers(request)) {
                    inbox.submitAnswers(request)
                }
            case .stop:
                EmptyView()
            }
        }
    }

    private func decisionButton(_ title: String, prominent: Bool, disabled: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(prominent ? .white : STheme.text)
                .padding(.horizontal, 18).frame(height: 32)
                .background(Capsule().fill(prominent ? STheme.accent : STheme.controlBg.opacity(0.8)))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .pointerCursorOnHover()
    }

    private func placeholder(for request: AgentRequest, listening: Bool) -> String {
        if listening { return "Listening…" }
        switch request.kind {
        case .stop: return "Answer \(request.agent)"
        case .permission: return "Or say what to do instead"
        case .question: return "Or answer in your own words"
        }
    }

    private func subtitle(for request: AgentRequest, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named  // "now" rather than "in 0 seconds"
        let age = formatter.localizedString(for: min(request.createdAt, now), relativeTo: now)
        let project = request.title == nil ? "" : " · \(request.projectName)"
        return "\(request.agent)\(project) · \(age)"
    }

    private func pager(for request: AgentRequest) -> some View {
        let index = inbox.pending.firstIndex { $0.id == request.id } ?? 0
        return HStack(spacing: 2) {
            pagerButton("chevron.left", disabled: index == 0) { inbox.selectedID = inbox.pending[index - 1].id }
            Text("\(index + 1)/\(inbox.pending.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(STheme.hint)
            pagerButton("chevron.right", disabled: index >= inbox.pending.count - 1) {
                inbox.selectedID = inbox.pending[index + 1].id
            }
        }
    }

    private func pagerButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundColor(disabled ? STheme.hint.opacity(0.4) : STheme.text)
        .disabled(disabled)
    }

    /// One line, like a chat box: the microphone on the left, the field, send on the right.
    /// While a reply is dictated the microphone opens into delete, recording and stop, and send
    /// stops the take and sends it.
    private func composer(for request: AgentRequest) -> some View {
        let listening = inbox.armedReplyID == request.id
        let hasDraft = !(inbox.drafts[request.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                AgentRecordingControls(
                    listening: listening,
                    onDictate: { inbox.dictateReply(to: request) },
                    onDelete: { inbox.discardDictation() },
                    onStop: { inbox.stopDictating() })

                // While the microphone is open the bar folds to one line that says so, then
                // opens back onto the whole reply: a multi-line draft beside the controls made a
                // tall bar with most of its width doing nothing.
                if listening {
                    Text(Self.listeningLabel(draft: inbox.drafts[request.id] ?? ""))
                        .font(.system(size: 13.5))
                        .foregroundColor(STheme.hint)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    replyField(for: request, listening: listening)
                        .transition(.opacity)
                }

                if listening {
                    composerButton("arrow.up", tint: .white, fill: STheme.accent,
                                   help: "Stop and send") { inbox.stopDictatingAndSend(request) }
                } else {
                    composerButton("arrow.up", tint: .white,
                                   fill: hasDraft ? STheme.accent : STheme.hint.opacity(0.35),
                                   help: "Send (⏎)") { inbox.send(request) }
                        .disabled(!hasDraft)
                }
            }
            .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(STheme.inputBg.opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(listening ? STheme.accent.opacity(0.7) : STheme.controlBorder.opacity(0.6), lineWidth: 1))
            .animation(AgentRecordingControls.morph, value: listening)

            shortcutHints(listening: listening)
                .padding(.leading, 14)
        }
        .onChange(of: listening) {
            guard !listening else { return }
            AgentPanelController.shared.focus()
            // The field is rebuilt as the bar unfolds; focus it once it is back.
            DispatchQueue.main.async { replyFocused = true }
        }
    }

    /// The keys that work here, spelled the way the user set them up. The recording trigger
    /// answers the agent once the panel has focus (a click in it is enough).
    private func shortcutHints(listening: Bool) -> some View {
        let hints = AgentShortcutHints.current(listening: listening)
        return HStack(spacing: 14) {
            ForEach(hints, id: \.action) { hint in
                HStack(spacing: 5) {
                    Text(hint.keys)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(STheme.text)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(STheme.controlBg.opacity(0.8)))
                    Text(hint.action)
                        .font(.system(size: 10.5))
                        .foregroundColor(STheme.hint)
                }
            }
        }
        .lineLimit(1)
    }

    /// The field grows with its text up to `replyMaxHeight`, then scrolls, and always to its
    /// last line: a dictated reply lands at the end, and the field used to stay on the first
    /// lines, hiding the words just added.
    private func replyField(for request: AgentRequest, listening: Bool) -> some View {
        let text = inbox.drafts[request.id] ?? ""
        return ScrollViewReader { proxy in
            ScrollView {
                TextField(placeholder(for: request, listening: listening), text: draft(for: request), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(.vertical, 8)
                    .focused($replyFocused)
                    .id(Self.replyEnd)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: Self.replyMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: text) {
                proxy.scrollTo(Self.replyEnd, anchor: .bottom)
            }
        }
    }

    /// What the folded bar reads: that it is listening, and how the reply so far ends, so a
    /// second take that continues a first still has its context.
    static func listeningLabel(draft: String) -> String {
        let soFar = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return soFar.isEmpty ? "Listening…" : "Listening… after \u{201C}\(soFar)\u{201D}"
    }

    static let replyEnd = "reply-end"
    /// About six lines of the reply's 13.5 pt text.
    static let replyMaxHeight: CGFloat = 116

    private func composerButton(_ symbol: String, tint: Color, fill: Color, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .help(help)
    }

    private func draft(for request: AgentRequest) -> Binding<String> {
        Binding(get: { inbox.drafts[request.id] ?? "" },
                set: { inbox.drafts[request.id] = $0 })
    }
}

/// Who is talking: the agent's own icon, tucked against OpenSuperWhisper's, the two of them
/// working together. The agent's icon comes from its desktop app when it is installed, so the
/// mark is the one the user already knows and nothing of theirs ships in this bundle; without
/// it, a symbol in the agent's colour stands in.
struct AgentAvatar: View {
    var kind: AgentKind = .claudeCode

    @MainActor private static var icons: [AgentKind: NSImage] = [:]

    @MainActor static func icon(for kind: AgentKind) -> NSImage? {
        if let cached = icons[kind] { return cached }
        guard let id = kind.iconBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[kind] = image
        return image
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            // Its own rounded square, as is: a shadow is enough to lift it off the other one.
            agent(size: 22)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .offset(x: 9, y: 5)
        }
        .frame(width: 46, height: 40, alignment: .topLeading)
    }

    @ViewBuilder private func agent(size: CGFloat) -> some View {
        if let icon = Self.icon(for: kind) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: Self.fallbackSymbol(kind))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Self.fallbackColor(kind)))
        }
    }

    private static func fallbackSymbol(_ kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        case .cursor: return "cursorarrow"
        case .unknown: return "terminal"
        }
    }

    private static func fallbackColor(_ kind: AgentKind) -> Color {
        switch kind {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(white: 0.12)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cursor: return Color(white: 0.2)
        case .unknown: return Color.gray
        }
    }
}

/// The shortcut hints under the composer, read from the user's own bindings.
struct AgentShortcutHints {
    let keys: String
    let action: String

    /// The user's own stop-and-submit binding, spelled out; nil when they have none.
    @MainActor static func submitKeys() -> String? {
        let prefs = AppPreferences.shared
        let submit = RecordingTrigger.resolve(
            mouseRaw: prefs.submitMouseButtonHotkey,
            modifierRaw: prefs.submitModifierOnlyHotkey,
            shortcut: KeyboardShortcuts.getShortcut(for: .toggleRecordAndSubmit))
        return ModifierChord(storageValue: prefs.submitModifierChord).map { $0.symbols.joined() }
            ?? (submit == .none ? nil : submit.caps.joined(separator: " "))
    }

    @MainActor static func current(listening: Bool) -> [AgentShortcutHints] {
        let prefs = AppPreferences.shared
        let trigger = RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers.first
            .map { $0.caps.joined(separator: " ") }
        var hints: [AgentShortcutHints] = []
        if listening {
            if let trigger { hints.append(.init(keys: trigger, action: "stop")) }
            // Return stands in for a stop-and-submit binding the user has not set up.
            hints.append(.init(keys: submitKeys() ?? "⏎", action: "stop and send"))
            hints.append(.init(keys: "esc", action: "delete"))
        } else {
            if let trigger { hints.append(.init(keys: trigger, action: "dictate")) }
            hints.append(.init(keys: "⏎", action: "send"))
            hints.append(.init(keys: "⇧⏎", action: "new line"))
        }
        return hints
    }
}


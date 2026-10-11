import AppKit
import KeyboardShortcuts
import OpenSuperWhisperCore
import SwiftUI

/// A floating panel in the top-right corner, shown while an agent waits. It does not take focus
/// when it appears, so it never steals keystrokes from what the user is typing; clicking into
/// its reply field makes it key, like Spotlight.
@MainActor
final class AgentPanelController {
    static let shared = AgentPanelController()

    static let width: CGFloat = 560
    /// From the screen's edges to the panel; the card sits a further `AgentPanelView.shadowRoom`
    /// inside it.
    static let margin: CGFloat = 8

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

    #if DEBUG
    /// Set by the snapshot probe, which fills the inbox to draw the panel off-screen and must
    /// not put a real panel on the user's screen.
    var isSnapshotting = false
    #endif

    func update(visible: Bool) {
        #if DEBUG
        if isSnapshotting { return }
        #endif
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
            // The card draws its own soft shadow; the window's would be cut from a cached
            // outline that lags behind the card as it grows.
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            // Light or dark comes from NSApp.appearance, which AppearanceController sets and
            // every window without an appearance of its own follows, this one included.
            let host = FirstClickHostingView(rootView: AgentPanelRoot())
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

/// The panel's content with the text size setting applied. Read through @AppStorage, like the
/// main window, so moving the slider redraws an open panel too.
struct AgentPanelRoot: View {
    @AppStorage("textScale", store: DefaultsStore.current) private var textScale: Double = TextScale.default
    #if DEBUG
    var showsFocus = false
    #endif

    var body: some View {
        panel.environment(\.appTextScale, textScale)
    }

    private var panel: AgentPanelView {
        #if DEBUG
        return AgentPanelView(inbox: .shared, showsFocus: showsFocus)
        #else
        return AgentPanelView(inbox: .shared)
        #endif
    }
}

struct AgentPanelView: View {
    @ObservedObject var inbox: AgentInbox
    #if DEBUG
    var showsFocus = false
    #endif

    /// Transparent margin inside the borderless panel, for the card's shadow.
    static let shadowRoom: CGFloat = 18

    /// Long replies scroll inside the card rather than growing it past most of the screen.
    private var maxMessageHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 900) * 0.55).rounded()
    }

    var body: some View {
        Group {
            if let request = inbox.current {
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
        // The shadow belongs to the card's shape alone: on the whole card it would also fall
        // from every AppKit-backed child (the scroll views, the field) as a grey halo.
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(STheme.cardBg)
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(STheme.border, lineWidth: 1))
        .padding(Self.shadowRoom)
    }

    private func composer(for request: AgentRequest) -> some View {
        #if DEBUG
        AgentComposer(inbox: inbox, request: request, showsFocus: showsFocus)
        #else
        AgentComposer(inbox: inbox, request: request)
        #endif
    }

    private func header(for request: AgentRequest) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AgentAvatar(kind: request.agentKind)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.displayTitle)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .lineLimit(1)
                // Redrawn every half minute so "2 minutes ago" keeps counting while it waits.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(subtitle(for: request, now: context.date))
                        .scaledFont(size: 12.5)
                        .foregroundColor(STheme.hint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if inbox.pending.count > 1 { pager(for: request) }
            Button { inbox.dismiss(request) } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundColor(STheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(STheme.fill))
                    .contentShape(Circle())
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
                .scaledFont(size: 14)
                .foregroundColor(STheme.text)
            if !request.message.isEmpty {
                Text(request.message)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = request.toolDetail, !detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .scaledFont(size: 12.5, design: .monospaced)
                        .foregroundColor(STheme.textBright)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.fill))
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
                            .scaledFont(size: 10.5, weight: .semibold)
                            .tracking(0.6)
                            .foregroundColor(STheme.accent)
                    }
                    Text(MarkdownView.inline(question.question))
                        .scaledFont(size: 14.5, weight: .medium)
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
                    .scaledFont(size: 14)
                    .foregroundColor(picked ? STheme.accent : STheme.hint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .scaledFont(size: 13.5, weight: .medium)
                        .foregroundColor(STheme.textBright)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .scaledFont(size: 12)
                            .foregroundColor(STheme.hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(picked ? STheme.accentSoft : STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(picked ? STheme.accent.opacity(0.6) : STheme.border, lineWidth: 1))
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
                .scaledFont(size: 13.5, weight: .semibold)
                .foregroundColor(prominent ? STheme.onAccent : STheme.textBright)
                .padding(.horizontal, 18).frame(height: 34)
                .background(Capsule().fill(prominent ? STheme.accent : STheme.fill))
                .overlay(Capsule().strokeBorder(prominent ? Color.clear : STheme.border, lineWidth: 1))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .pointerCursorOnHover()
    }

    private func subtitle(for request: AgentRequest, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named  // "now" rather than "in 0 seconds"
        formatter.unitsStyle = .short  // "40 sec. ago" leaves room for the pager
        let age = formatter.localizedString(for: min(request.createdAt, now), relativeTo: now)
        let project = request.title == nil ? "" : " · \(request.projectName)"
        return "\(request.agent)\(project) · \(age)"
    }

    private func pager(for request: AgentRequest) -> some View {
        let index = inbox.pending.firstIndex { $0.id == request.id } ?? 0
        return HStack(spacing: 6) {
            pagerButton("chevron.left", disabled: index == 0) { inbox.selectedID = inbox.pending[index - 1].id }
            Text(verbatim: "\(index + 1)/\(inbox.pending.count)")
                .scaledFont(size: 12, weight: .medium)
                .monospacedDigit()
                .foregroundColor(STheme.textSecondary)
            pagerButton("chevron.right", disabled: index >= inbox.pending.count - 1) {
                inbox.selectedID = inbox.pending[index + 1].id
            }
        }
    }

    private func pagerButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 10, weight: .bold)
                .foregroundColor(disabled ? STheme.faint : STheme.textBright)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(disabled ? Color.clear : STheme.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

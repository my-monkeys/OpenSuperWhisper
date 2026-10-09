import AppKit
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

    private init() {}

    func update(visible: Bool) {
        if visible { show() } else { hide() }
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
            let host = NSHostingView(rootView: AgentPanelView(inbox: .shared))
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

/// Borderless panels refuse key status by default, which would leave the reply field unable to
/// take typing.
final class AgentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct AgentPanelView: View {
    @ObservedObject var inbox: AgentInbox
    /// Which waiting agent is shown when several are; falls back to the oldest.
    @State private var selectedID: String?

    /// Long replies scroll inside the card rather than growing it past most of the screen.
    private var maxMessageHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 900) * 0.55).rounded()
    }

    private var current: AgentRequest? {
        inbox.pending.first { $0.id == selectedID } ?? inbox.pending.first
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
                MarkdownView(markdown: request.message.isEmpty ? "_No message._" : request.message)
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: maxMessageHeight)
            .fixedSize(horizontal: false, vertical: true)
            composer(for: request)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(10)  // room for the shadow inside the borderless panel
    }

    private func header(for request: AgentRequest) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(STheme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(STheme.accentSoft))
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
            pagerButton("chevron.left", disabled: index == 0) { selectedID = inbox.pending[index - 1].id }
            Text("\(index + 1)/\(inbox.pending.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(STheme.hint)
            pagerButton("chevron.right", disabled: index >= inbox.pending.count - 1) {
                selectedID = inbox.pending[index + 1].id
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
    private func composer(for request: AgentRequest) -> some View {
        let listening = inbox.armedReplyID == request.id
        let hasDraft = !(inbox.drafts[request.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(alignment: .bottom, spacing: 10) {
            Button { inbox.dictateReply(to: request) } label: {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(listening ? .white : STheme.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(listening ? STheme.accent : STheme.accentSoft))
                    .symbolEffect(.variableColor.iterative, isActive: listening)
            }
            .buttonStyle(.plain)
            .pointerCursorOnHover()
            .help(listening ? "Listening. Stop as usual, with your trigger or the stop phrase"
                            : "Dictate the answer")
            .disabled(listening)

            TextField(listening ? "Listening…" : "Answer \(request.agent)", text: draft(for: request), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...6)
                .padding(.vertical, 8)
                .onSubmit { inbox.send(request) }

            Button { inbox.send(request) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(hasDraft ? STheme.accent : STheme.hint.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!hasDraft)
            .help("Send (⏎)")
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(STheme.inputBg.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(listening ? STheme.accent.opacity(0.7) : STheme.controlBorder.opacity(0.6), lineWidth: 1))
    }

    private func draft(for request: AgentRequest) -> Binding<String> {
        Binding(get: { inbox.drafts[request.id] ?? "" },
                set: { inbox.drafts[request.id] = $0 })
    }
}

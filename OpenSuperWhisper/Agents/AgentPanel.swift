import AppKit
import SwiftUI

/// A floating panel in the top-right corner, shown while an agent waits. It does not take focus
/// when it appears, so it never steals keystrokes from what the user is typing; clicking into
/// its reply field makes it key, like Spotlight.
@MainActor
final class AgentPanelController {
    static let shared = AgentPanelController()

    static let width: CGFloat = 380
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

    var body: some View {
        Group {
            if let request = inbox.pending.first {
                card(for: request)
            }
        }
        .frame(width: AgentPanelController.width)
    }

    private func card(for request: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(for: request)
            ScrollView {
                Text(Self.rendered(request.message))
                    .font(.system(size: 12))
                    .foregroundColor(STheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Reply, or dictate it", text: draft(for: request), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(inbox.armedReplyID == request.id ? STheme.accent : STheme.controlBorder, lineWidth: 1))
                .onSubmit { inbox.send(request) }

            actions(for: request)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(STheme.windowBg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(STheme.controlBorder, lineWidth: 1))
    }

    private func header(for request: AgentRequest) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(STheme.accent)
            Text("\(request.agent) · \(request.projectName)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(STheme.textBright)
                .lineLimit(1)
            Spacer(minLength: 6)
            if inbox.pending.count > 1 {
                Text("\(inbox.pending.count - 1) more waiting")
                    .font(.system(size: 10.5))
                    .foregroundColor(STheme.hint)
            }
        }
    }

    private func actions(for request: AgentRequest) -> some View {
        let listening = inbox.armedReplyID == request.id
        let hasDraft = !(inbox.drafts[request.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 8) {
            Button {
                inbox.dictateReply(to: request)
            } label: {
                Label(listening ? "Listening…" : "Dictate", systemImage: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .disabled(listening)
            Spacer()
            Button("Let it stop") { inbox.dismiss(request) }
                .font(.system(size: 11.5))
                .help("The agent stops and waits in its terminal, as it would without OpenSuperWhisper")
            Button("Send") { inbox.send(request) }
                .font(.system(size: 11.5, weight: .semibold))
                .disabled(!hasDraft)
        }
        .controlSize(.small)
    }

    private func draft(for request: AgentRequest) -> Binding<String> {
        Binding(get: { inbox.drafts[request.id] ?? "" },
                set: { inbox.drafts[request.id] = $0 })
    }

    /// The agent writes Markdown; inline styling (bold, code, links) reads better than the raw
    /// asterisks and backticks, and blocks stay as written.
    static func rendered(_ message: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message, options: options)) ?? AttributedString(message)
    }
}

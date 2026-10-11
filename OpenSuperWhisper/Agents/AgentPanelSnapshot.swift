#if DEBUG
import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// Made-up waiting agents for `UISnapshotProbe`, so the panel can be drawn off-screen. The
/// requests are written to the agents folder, which under the probe's test isolation is a
/// throwaway one, and their hook is the probe itself, so the inbox takes them as live.
@MainActor
enum AgentPanelSnapshot {
    static func make(draft: String? = nil, showing kind: AgentRequest.Kind = .stop, focused: Bool = false) -> AnyView {
        AgentPanelController.shared.isSnapshotting = true
        let requests = seed()
        AgentInbox.shared.reload()
        AgentInbox.shared.selectedID = requests.first { $0.kind == kind }?.id
        if let draft, let first = requests.first { AgentInbox.shared.drafts[first.id] = draft }
        return AnyView(
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .underPageBackgroundColor)
                AgentPanelRoot(showsFocus: focused)
                    .fixedSize()
            }
        )
    }

    private static func seed() -> [AgentRequest] {
        guard let directory = AgentBridge.requestsDirectory else { return [] }
        try? FileManager.default.removeItem(at: directory)
        let now = Date()
        let requests = [
            request(kind: .stop, title: "Faster clipboard restore", age: 40, message: """
                Done. The previous clipboard now comes back after **0.5 s** instead of 1 s, and the delay is a setting.

                - `ClipboardUtil.borrowForPaste` restores after `clipboardRestoreDelayMs`
                - New slider in **Settings › Output** (150 to 2000 ms)
                - 4 new tests, all 312 passing

                Want me to open the PR?
                """, now: now),
            {
                var permission = request(kind: .permission, title: "Release notes", age: 25,
                                         message: "Push the branch so the PR can be opened.", now: now)
                permission.tool = "Bash"
                permission.toolDetail = "git push -u origin feat/clipboard-delay"
                return permission
            }(),
            {
                var question = request(kind: .question, title: "Settings search", age: 10, message: "", now: now)
                question.questions = [AgentQuestion(
                    question: "Should the search also match **French** keywords?", header: "Search",
                    options: [.init(label: "Yes, both languages", description: "Adds the French synonyms to every row."),
                              .init(label: "English only")])]
                return question
            }(),
        ]
        for request in requests {
            try? AgentBridge.write(request, to: directory.appendingPathComponent("\(request.id).json"))
        }
        return requests
    }

    private static func request(kind: AgentRequest.Kind, title: String, age: TimeInterval,
                                message: String, now: Date) -> AgentRequest {
        let created = now.addingTimeInterval(-age)
        return AgentRequest(id: UUID().uuidString, kind: kind, agent: "Claude Code", sessionID: "snapshot",
                            title: title, cwd: "/Users/demo/code/OpenSuperWhisper", message: message,
                            createdAt: created, expiresAt: created.addingTimeInterval(600),
                            hookPID: getpid())
    }
}
#endif

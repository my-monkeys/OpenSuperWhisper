import AppKit
import Combine
import Foundation

/// The agents waiting on the user, as the app sees them. Fed by the hook's request files, it
/// drives the floating panel and writes the user's answers back.
@MainActor
final class AgentInbox: ObservableObject {
    static let shared = AgentInbox()

    /// Oldest first: the panel answers them in the order the agents stopped.
    @Published private(set) var pending: [AgentRequest] = []
    /// What the user has typed or dictated so far, per request, before sending.
    @Published var drafts: [String: String] = [:]
    /// The request a dictation in progress is answering. Taken by the recording when it stops,
    /// so the words go to the agent instead of being pasted wherever the cursor is.
    @Published private(set) var armedReplyID: String?

    private var timer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started, !DefaultsStore.isRunningTests else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: AgentBridge.requestNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AgentInbox.shared.reload() }
        }
        // The notification can be missed (the app was busy launching); the requests directory
        // is the truth, and this also drops requests whose hook has gone.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AgentInbox.shared.reload() }
        }
        reload()
    }

    func reload() {
        let requests = Self.loadRequests(now: Date())
        if requests != pending { pending = requests }
        for id in drafts.keys where !requests.contains(where: { $0.id == id }) {
            drafts[id] = nil
        }
        if let armed = armedReplyID, !requests.contains(where: { $0.id == armed }) {
            armedReplyID = nil
        }
        AgentPanelController.shared.update(visible: !pending.isEmpty)
    }

    /// Live requests on disk: not expired, and their hook still waiting.
    static func loadRequests(now: Date) -> [AgentRequest] {
        guard let directory = AgentBridge.requestsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return [] }
        var live: [AgentRequest] = []
        for file in files where file.pathExtension == "json" {
            guard let request = AgentBridge.read(AgentRequest.self, from: file) else { continue }
            if request.expiresAt > now && AgentBridge.isAlive(pid: request.hookPID) {
                live.append(request)
            } else {
                // Its hook was cancelled (Esc in the terminal) or killed, so nothing will
                // clean up after it.
                try? FileManager.default.removeItem(at: file)
            }
        }
        return live.sorted { $0.createdAt < $1.createdAt }
    }

    func send(_ request: AgentRequest) {
        let text = (drafts[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer(request, with: AgentResponse(action: .reply, text: text))
    }

    func dismiss(_ request: AgentRequest) {
        answer(request, with: AgentResponse(action: .dismiss))
    }

    private func answer(_ request: AgentRequest, with response: AgentResponse) {
        guard let url = AgentBridge.responseURL(request.id) else { return }
        try? AgentBridge.write(response, to: url)
        pending.removeAll { $0.id == request.id }
        drafts[request.id] = nil
        if armedReplyID == request.id { armedReplyID = nil }
        AgentPanelController.shared.update(visible: !pending.isEmpty)
    }

    /// Starts a dictation whose words answer this request. Pressing the trigger (or saying the
    /// stop phrase) ends it as usual.
    func dictateReply(to request: AgentRequest) {
        armedReplyID = request.id
        ShortcutManager.shared.toggleRecordingFromApp()
    }

    /// Hands the armed request to the recording that is stopping, and disarms.
    func takeArmedReply() -> String? {
        defer { armedReplyID = nil }
        return armedReplyID
    }

    /// The finished dictation for a reply. Added to the draft so a second take continues the
    /// first; `send` is the "press enter" voice command or the submit shortcut, which send it.
    func receiveDictation(_ text: String, for id: String, send: Bool) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        let existing = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let added = text.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[id] = [existing, added].filter { !$0.isEmpty }.joined(separator: " ")
        if send { self.send(request) }
    }
}

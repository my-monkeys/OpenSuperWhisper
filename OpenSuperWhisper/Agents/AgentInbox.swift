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
    /// Which waiting agent the panel shows when several are; nil means the oldest.
    @Published var selectedID: String?
    /// A reply whose dictation should go out as soon as it is transcribed (the panel's send
    /// button pressed while recording).
    private var sendWhenTranscribedID: String?

    var current: AgentRequest? {
        pending.first { $0.id == selectedID } ?? pending.first
    }

    /// For questions: the options picked so far, per request, per question.
    @Published var selections: [String: [String: Set<String>]] = [:]

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
        for id in selections.keys where !requests.contains(where: { $0.id == id }) {
            selections[id] = nil
        }
        if let selected = selectedID, !requests.contains(where: { $0.id == selected }) {
            selectedID = nil
        }
        if let armed = armedReplyID, !requests.contains(where: { $0.id == armed }) {
            armedReplyID = nil
        }
        AgentPanelController.shared.update(visible: !pending.isEmpty)
    }

    /// Live requests on disk: not expired, their hook still waiting, and not answered yet.
    nonisolated static func loadRequests(
        now: Date,
        requests: URL? = AgentBridge.requestsDirectory,
        responses: URL? = AgentBridge.responsesDirectory
    ) -> [AgentRequest] {
        guard let requests, let responses,
              let files = try? FileManager.default.contentsOfDirectory(
                at: requests, includingPropertiesForKeys: nil) else { return [] }
        var live: [AgentRequest] = []
        for file in files where file.pathExtension == "json" {
            guard let request = AgentBridge.read(AgentRequest.self, from: file) else { continue }
            guard request.expiresAt > now && AgentBridge.isAlive(pid: request.hookPID) else {
                // Its hook was cancelled (Esc in the terminal) or killed, so nothing will
                // clean up after it.
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Answered: the request file stays until the hook's next poll reads the answer and
            // deletes both. Listing it in that gap would bring the panel back for a moment
            // after the user sent.
            let response = responses.appendingPathComponent("\(request.id).json")
            if !FileManager.default.fileExists(atPath: response.path) {
                live.append(request)
            }
        }
        return live.sorted { $0.createdAt < $1.createdAt }
    }

    /// Sends what the composer holds, which means something different per kind: the next
    /// instruction after a stop, a refusal with directions for a permission, a free answer
    /// for a question.
    func send(_ request: AgentRequest) {
        let text = (drafts[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.kind {
        case .stop:
            guard !text.isEmpty else { return }
            answer(request, with: AgentResponse(action: .reply, text: text))
        case .permission:
            guard !text.isEmpty else { return }
            deny(request)
        case .question:
            submitAnswers(request)
        }
    }

    func allow(_ request: AgentRequest) {
        answer(request, with: AgentResponse(action: .allow))
    }

    /// Refuses; whatever is in the composer goes along as what to do instead.
    func deny(_ request: AgentRequest) {
        let text = (drafts[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        answer(request, with: AgentResponse(action: .deny, text: text))
    }

    func toggle(_ option: String, in question: AgentQuestion, of request: AgentRequest) {
        var picked = selections[request.id]?[question.question] ?? []
        if question.multiSelect {
            if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
        } else {
            picked = picked == [option] ? [] : [option]
        }
        selections[request.id, default: [:]][question.question] = picked
    }

    func isPicked(_ option: String, in question: AgentQuestion, of request: AgentRequest) -> Bool {
        selections[request.id]?[question.question]?.contains(option) == true
    }

    /// Answers keyed by question, in the form AskUserQuestion takes: picked labels joined with
    /// commas, or the composer's text for the first question nothing was picked for.
    func answers(for request: AgentRequest) -> [String: String] {
        var free = (drafts[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var answers: [String: String] = [:]
        for question in request.questions ?? [] {
            let picked = question.options.map(\.label).filter { isPicked($0, in: question, of: request) }
            if !picked.isEmpty {
                answers[question.question] = picked.joined(separator: ", ")
            } else if !free.isEmpty {
                answers[question.question] = free
                free = ""
            }
        }
        return answers
    }

    func canSubmitAnswers(_ request: AgentRequest) -> Bool {
        answers(for: request).count == (request.questions?.count ?? 0)
    }

    func submitAnswers(_ request: AgentRequest) {
        guard canSubmitAnswers(request) else { return }
        answer(request, with: AgentResponse(action: .answer, answers: answers(for: request)))
    }

    func dismiss(_ request: AgentRequest) {
        answer(request, with: AgentResponse(action: .dismiss))
    }

    private func answer(_ request: AgentRequest, with response: AgentResponse) {
        guard let url = AgentBridge.responseURL(request.id) else { return }
        try? AgentBridge.write(response, to: url)
        pending.removeAll { $0.id == request.id }
        drafts[request.id] = nil
        selections[request.id] = nil
        if armedReplyID == request.id { armedReplyID = nil }
        AgentPanelController.shared.update(visible: !pending.isEmpty)
    }

    /// Starts a dictation whose words answer this request. Pressing the trigger (or saying the
    /// stop phrase) ends it as usual.
    func dictateReply(to request: AgentRequest) {
        armedReplyID = request.id
        // The panel shows the recording itself, with its own stop and delete buttons.
        ShortcutManager.shared.toggleRecordingFromApp(showBubble: false)
    }

    /// Ends the reply being dictated; its text then lands in the composer as usual.
    func stopDictating() {
        ShortcutManager.shared.toggleRecordingFromApp()
    }

    /// Ends the reply being dictated and sends it once its words are in.
    func stopDictatingAndSend(_ request: AgentRequest) {
        sendWhenTranscribedID = request.id
        stopDictating()
    }

    /// The user's own recording trigger, pressed while the panel has focus: the take answers
    /// the agent on screen, with the panel's controls instead of the bubble. Returns whether it
    /// took the press; the caller then starts the recording as usual.
    func claimTrigger() -> Bool {
        guard armedReplyID == nil, AgentPanelController.shared.hasFocus, let request = current else {
            return false
        }
        armedReplyID = request.id
        return true
    }

    /// Throws the reply being dictated away.
    func discardDictation() {
        ShortcutManager.shared.cancelRecordingFromApp()
        armedReplyID = nil
    }

    /// Hands the armed request to the recording that is stopping, and disarms.
    func takeArmedReply() -> String? {
        defer { armedReplyID = nil }
        return armedReplyID
    }

    /// The finished dictation for a reply. Added to the draft so a second take continues the
    /// first; `send` is the "press enter" voice command or the submit shortcut, which send it.
    func receiveDictation(_ text: String, for id: String, send requested: Bool) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        let send = requested || sendWhenTranscribedID == id
        if sendWhenTranscribedID == id { sendWhenTranscribedID = nil }
        let added = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.kind {
        case .permission:
            // "Yes" or "no" on its own decides; anything longer is directions for a refusal.
            switch Self.verdict(added) {
            case .some(true): allow(request); return
            case .some(false): deny(request); return
            case .none: break
            }
        case .question:
            // Saying an option picks it; saying something else is a free answer.
            if let question = request.questions?.first,
               let option = Self.option(matching: added, in: question) {
                if !isPicked(option, in: question, of: request) { toggle(option, in: question, of: request) }
                if send || request.questions?.count == 1 { submitAnswers(request) }
                return
            }
        case .stop:
            break
        }
        let existing = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[id] = [existing, added].filter { !$0.isEmpty }.joined(separator: " ")
        if send { self.send(request) }
    }

    /// true for a spoken yes, false for a no, nil for anything else. Only a short answer counts,
    /// so "no, use the other file" stays directions rather than a bare refusal.
    nonisolated static func verdict(_ text: String) -> Bool? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard (1...3).contains(words.count) else { return nil }
        // Words, not phrases: "d'accord" and "vas-y" arrive split at the apostrophe and dash.
        let yes: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "allow", "approve", "go",
                                "oui", "ouais", "vas", "vasy", "valide", "autorise", "accepte", "accord"]
        let no: Set<String> = ["no", "nope", "deny", "refuse", "stop", "non", "annule", "nan"]
        if words.contains(where: no.contains) { return false }
        if words.contains(where: yes.contains) { return true }
        return nil
    }

    /// The option whose label the dictation names, ignoring case and punctuation.
    nonisolated static func option(matching text: String, in question: AgentQuestion) -> String? {
        func normalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let said = normalized(text)
        guard !said.isEmpty else { return nil }
        return question.options.first { normalized($0.label) == said }?.label
            ?? question.options.first { said.contains(normalized($0.label)) }?.label
    }
}

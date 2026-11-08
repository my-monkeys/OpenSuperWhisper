import Foundation

/// The Feedback card's draft and where its sending stands. Owned by the main window rather than
/// by the card, so a click outside the card or Esc closes it without losing what was typed.
@MainActor
final class FeedbackFormModel: ObservableObject {
    enum Status: Equatable {
        /// `failed`: worth another try. `refused`: the API turned this message down, so the
        /// same text will never get through.
        case editing, sending, sent, failed, refused
        /// The recording could not be read, or the API would not take it (too big, or too
        /// many bytes from this connection this hour): the message may go without it.
        case audioFailed
    }

    /// What the card says it sends besides the text, shown word for word under the app details.
    enum Disclosure: Equatable {
        case textOnly, withRecording
    }

    /// What keeps a message within the API's limits from being sent as it stands.
    enum LimitProblem: Equatable {
        case messageTooLong, emailTooLong
    }

    static let minimumMessageLength = 2
    /// The character counter shows from here on, so a long report sees the limit coming.
    static let counterThreshold = FeedbackSender.maxMessageLength * 9 / 10

    @Published var kind: FeedbackKind = .idea
    @Published var message = ""
    @Published var email = ""
    @Published var includeDetails = true
    @Published private(set) var status: Status = .editing
    /// The dictation whose audio goes with the message. Nothing is attached unless the user picks one.
    @Published private(set) var attachedAudio: DictationAudioChoice?
    @Published private(set) var recentDictations: [DictationAudioChoice] = []
    @Published var isPickingAudio = false

    private let sender: FeedbackSender
    private let appDetails: @MainActor () -> String
    private let loadRecentDictations: @MainActor () async -> [DictationAudioChoice]
    /// Run once a message got through: whoever sent one is never asked for feedback (#206).
    private let onSent: @MainActor () -> Void

    /// Nonisolated so the main window can create it as the default of its own initializer.
    nonisolated init(sender: FeedbackSender = FeedbackSender(),
                     appDetails: @escaping @MainActor () -> String = { FeedbackAppDetails.current() },
                     recentDictations: @escaping @MainActor () async -> [DictationAudioChoice] = { await DictationAudioChoice.recent() },
                     onSent: @escaping @MainActor () -> Void = FeedbackPrompt.markDone) {
        self.sender = sender
        self.appDetails = appDetails
        self.loadRecentDictations = recentDictations
        self.onSent = onSent
    }

    /// The exact line sent when "Include app details" is on.
    var details: String { appDetails() }

    /// Off while a send is in flight: Cancel would drop a draft the request still carries, and
    /// a success clears the form, words typed after Send included.
    var isEditable: Bool { status != .sending }

    var canSend: Bool {
        isEditable
            && message.filter { !$0.isWhitespace }.count >= Self.minimumMessageLength
            && limitProblem == nil
    }

    /// Counted as the API counts: UTF-16 units of the trimmed text.
    var messageLength: Int { submission.trimmedMessage.utf16.count }

    var showsCounter: Bool { messageLength >= Self.counterThreshold }

    var limitProblem: LimitProblem? {
        let submission = submission
        if submission.trimmedEmail.utf16.count > FeedbackSender.maxEmailLength { return .emailTooLong }
        return FeedbackSender.fitsLimits(submission) ? nil : .messageTooLong
    }

    var submission: FeedbackSubmission {
        FeedbackSubmission(kind: kind, message: message, email: email,
                           details: includeDetails ? details : nil, audio: attachedAudio)
    }

    var disclosure: Disclosure { attachedAudio == nil ? .textOnly : .withRecording }

    func refreshRecentDictations() async {
        recentDictations = await loadRecentDictations()
    }

    func attach(_ audio: DictationAudioChoice) {
        guard isEditable, audio.isAttachable else { return }
        attachedAudio = audio
        isPickingAudio = false
    }

    func detachAudio() {
        guard isEditable else { return }
        attachedAudio = nil
    }

    func send() async {
        guard canSend else { return }
        status = .sending
        do {
            try await sender.send(submission)
            onSent()
            clearDraft()
            status = .sent
        } catch FeedbackSendError.refused(let code) {
            status = attachedAudio != nil && (code == 413 || code == 429) ? .audioFailed : .refused
        } catch FeedbackSendError.audioUnavailable {
            status = .audioFailed
        } catch {
            status = .failed
        }
    }

    /// The card closed: a thank-you or an error is not shown again next time. A send still in
    /// flight keeps its status, and lands on the thank-you if it gets through.
    func cardClosed() {
        if status != .sending { status = .editing }
    }

    /// Cancel: the draft is dropped, unlike a click outside the card. Not while it is being
    /// sent: a failure would then come back over an empty form.
    func discard() {
        guard isEditable else { return }
        clearDraft()
        cardClosed()
    }

    private func clearDraft() {
        kind = .idea
        message = ""
        email = ""
        includeDetails = true
        attachedAudio = nil
        isPickingAudio = false
    }

    #if DEBUG
    /// For the snapshot probe, which shows the thank-you without sending anything.
    func stageStatus(_ status: Status) { self.status = status }

    func stageAudio(_ audio: DictationAudioChoice?, choices: [DictationAudioChoice], picking: Bool = false) {
        attachedAudio = audio
        recentDictations = choices
        isPickingAudio = picking
    }
    #endif
}

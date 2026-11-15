import SwiftUI
import OpenSuperWhisperCore

/// "Report this transcription", as a card over the main window (#168): what went wrong, what it
/// should have written, a comment, and for a wrong word or name the fix for next time, added to
/// the dictionary on the spot. The report is saved on this Mac with the audio; nothing is sent.
struct ReportCard: View {
    let recording: Recording
    /// Whether the dictionary rules run at all. Off by default, so an entry added here would
    /// change nothing until it is switched on: the card says so and offers the switch.
    @Binding var dictionaryEnabled: Bool
    let addToDictionary: (CustomDictionaryEntry) -> Void
    @ObservedObject var reports: TranscriptionReportsModel
    @ObservedObject private var navigation = AppNavigation.shared
    @Environment(\.textScaleFactor) private var textScale

    private enum Status { case editing, saving, saved, failed }
    private enum SendStatus { case idle, sending, sent, failed }

    @State private var draft: ReportDraft
    @State private var status: Status
    /// The words last added, so the button reads "Added" until either field changes.
    @State private var added: (wrong: String, right: String)?
    /// The one-tap text copy to the developer, offered after the local save.
    @State private var sendStatus: SendStatus = .idle
    /// Whether the dictation's recording goes with the text. On whenever the file can go: a
    /// transcription report rarely reproduces without the audio it was made from, and the switch
    /// is right above Send for whoever would rather keep it.
    @State private var includeAudio: Bool
    /// Read once for the card: the audio's presence and size decide what the switch offers.
    @State private var audio: DictationAudioChoice

    private static let editorBaseHeight: CGFloat = 76
    private static let editorMaxHeight: CGFloat = 110
    /// Taller than the comment: it holds the whole dictation.
    private static let expectedBaseHeight: CGFloat = 96
    private static let expectedMaxHeight: CGFloat = 150

    #if DEBUG
    /// For the snapshot probe: a draft already filled in, or the card after Save.
    static var snapshotDraft: ReportDraft?
    static var snapshotSaved = false
    static var snapshotIncludeAudio: Bool?
    #endif

    init(recording: Recording, dictionaryEnabled: Binding<Bool>,
         addToDictionary: @escaping (CustomDictionaryEntry) -> Void, reports: TranscriptionReportsModel) {
        self.recording = recording
        self._dictionaryEnabled = dictionaryEnabled
        self.addToDictionary = addToDictionary
        self.reports = reports
        var draft = reports.draft(for: recording)
        var status = Status.editing
        #if DEBUG
        draft = Self.snapshotDraft ?? draft
        status = Self.snapshotSaved ? .saved : status
        #endif
        let audio = DictationAudioChoice.forRecording(recording)
        var includeAudio = audio.isAttachable
        #if DEBUG
        includeAudio = Self.snapshotIncludeAudio ?? includeAudio
        #endif
        _draft = State(initialValue: draft)
        _status = State(initialValue: status)
        _audio = State(initialValue: audio)
        _includeAudio = State(initialValue: includeAudio)
    }

    var body: some View {
        ModalCard(maxWidth: 620, maxHeight: 900, hugsContent: true, onClose: close) {
            VStack(spacing: 0) {
                header
                if status == .saved {
                    saved
                } else {
                    ScrollView { form }
                        .scrollBounceBehavior(.basedOnSize)
                    footer
                }
            }
        }
        .onChange(of: draft) { _, draft in
            reports.keepDraft(draft, for: recording)
        }
    }

    /// ✕, Esc, a click outside and any other card opening keep what was typed for next time, as
    /// the Feedback card does: the draft is mirrored into the model as it changes.
    private func close() {
        navigation.reporting = nil
    }

    private func cancel() {
        reports.discardDraft(for: recording.id)
        navigation.reporting = nil
    }

    private func save() {
        saveThen {}
    }

    /// The first screen's main action: the report is kept on this Mac first, so a failed send
    /// still leaves it saved, with Send offered again on the next screen.
    private func saveAndSend() {
        saveThen(sendToDeveloper)
    }

    private func saveThen(_ next: @escaping () -> Void) {
        status = .saving
        Task {
            do {
                try await reports.save(draft, for: recording)
                status = .saved
                next()
            } catch {
                status = .failed
            }
        }
    }

    /// Sends the text of the report to the developer, with the dictation's recording when the
    /// audio switch is on. Only ever after the local save, so the full report with its audio is
    /// already kept whatever the network does.
    private func sendToDeveloper() {
        sendStatus = .sending
        Task {
            do {
                try await DictationReportSender.send(recording: recording,
                                                     problem: draft.problem, comment: draft.comment,
                                                     expected: draft.correctedText,
                                                     includeAudio: includeAudio)
                sendStatus = .sent
            } catch {
                sendStatus = .failed
            }
        }
    }

    // MARK: - Layout

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Report this transcription")
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text("Saved on this Mac with the audio, the model and both texts. Nothing is sent unless you share it.")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            CloseButton(action: close)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReportTranscriptPreview(recording: recording)
            VStack(alignment: .leading, spacing: 8) {
                fieldTitle("What went wrong?")
                FlowLayout(spacing: 8) {
                    ForEach(TranscriptionReport.Problem.offered, id: \.self) { problem in
                        SFilterChip(label: Text(problem.label), selected: draft.problem == problem) {
                            draft.problem = problem
                        }
                    }
                }
            }
            if draft.asksForExpectedText {
                expectedField
            }
            if draft.showsWordFields {
                wordFix
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldTitle(commentTitle)
                SEditor(text: $draft.comment,
                        height: min(Self.editorBaseHeight * textScale, Self.editorMaxHeight),
                        fontSize: 14, monospaced: false,
                        placeholder: draft.asksForExpectedText
                            ? "Anything else that helps."
                            : "What you said, what you expected, anything that helps.")
                    .accessibilityLabel(Text(commentTitle))
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // A text view takes Esc for word completion, so the card's own Esc never hears it.
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    /// "Something else" has no text to correct, so its comment is what the report needs.
    private var commentTitle: LocalizedStringKey {
        draft.problem == .other ? "Comment" : "Comment (optional)"
    }

    /// The text it should have written, starting as the text it did write. Required: the same
    /// audio gives the same text on the maintainer's Mac, so this is what says what was wrong.
    private var expectedField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldTitle("What it should have written")
            Text("Starts as the text you got. Fix the words that came out wrong.")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            SEditor(text: $draft.expected,
                    height: min(Self.expectedBaseHeight * textScale, Self.expectedMaxHeight),
                    fontSize: 14, monospaced: false,
                    placeholder: "What you said")
                .accessibilityLabel(Text("What it should have written"))
        }
    }

    private func fieldTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundColor(STheme.textBright)
    }

    // MARK: - Dictionary

    private var wordFix: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                fieldTitle("Fix it next time")
                Text("Add the right spelling to your dictionary. Leave “Written as” empty to add it as a new word.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { wordFields }
                VStack(alignment: .leading, spacing: 10) { wordFields }
            }
            HStack(spacing: 12) {
                addButton
                if !dictionaryEnabled {
                    dictionaryOffNotice
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.advancedBg))
    }

    @ViewBuilder private var wordFields: some View {
        wordField("Written as", prompt: "What the model wrote", text: $draft.writtenAs)
        wordField("Should be", prompt: "The right spelling", text: $draft.shouldBe)
    }

    private func wordField(_ title: LocalizedStringKey, prompt: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.textBright)
            STextField(prompt, text: text, width: nil)
                .accessibilityLabel(Text(title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictionaryOffNotice: some View {
        HStack(spacing: 8) {
            Text("The dictionary is off, so this changes nothing yet.")
                .scaledFont(size: 12)
                .foregroundColor(STheme.warn)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Button("Turn it on") { dictionaryEnabled = true }
                .buttonStyle(.plain)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(STheme.accent)
                .fixedSize()
        }
    }

    private var isAdded: Bool {
        guard let added, let entry = draft.dictionaryEntry else { return false }
        return added.wrong == entry.original && added.right == entry.replacement
    }

    @ViewBuilder private var addButton: some View {
        if isAdded {
            Label("Added to the dictionary", systemImage: "checkmark")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.ok)
        } else {
            Button("Add to dictionary") {
                guard let entry = draft.dictionaryEntry else { return }
                addToDictionary(entry)
                added = (entry.original, entry.replacement)
            }
            .buttonStyle(.sSecondary)
            .disabled(draft.dictionaryEntry == nil)
        }
    }

    // MARK: - Footer and saved state

    /// The audio switch sits with the buttons rather than at the end of the form: the audio goes
    /// by default, so what Save and send will take must be in view next to it, not below the fold.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if audio.eligibility != .noAudio {
                audioSwitch
            }
            footerButtons
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            if status == .failed {
                Label {
                    Text("Couldn't save the report.")
                        .scaledFont(size: 13, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").scaledFont(size: 13)
                }
                .foregroundColor(STheme.warn)
                .layoutPriority(1)
            } else if let missing = draft.missing {
                Text(missingHint(missing))
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.sSecondary)
            Button("Save report", action: save)
                .buttonStyle(.sSecondary)
                .disabled(!draft.canSave || status == .saving)
            Button("Save and send", action: saveAndSend)
                .buttonStyle(.sPrimary)
                .disabled(!draft.canSave || status == .saving)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    /// Why Save is greyed out, next to it.
    private func missingHint(_ missing: ReportDraft.Missing) -> LocalizedStringKey {
        switch missing {
        case .problem: return "Pick what went wrong."
        case .expectedText: return "Edit the text into what you said to save the report."
        case .comment: return "Add a comment to save the report."
        }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 26)
                    .foregroundColor(STheme.ok)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Report saved")
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundColor(STheme.textBright)
                    savedMessage
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.vertical, 28)
            if audio.eligibility != .noAudio && !sendStarted {
                audioSwitch
                    .padding(.horizontal, 26).padding(.bottom, 16)
            }
            // Sending is what the saved report is for, so it takes the primary place on the right.
            // There is no Done beside it: the card closes from its ✕, Esc or a click outside.
            HStack(spacing: 10) {
                Button("Show reports") { navigation.openReports() }
                    .buttonStyle(.sSecondary)
                Spacer(minLength: 0)
                sendButton
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Sent, or on its way: the saved screen then only shows the report, with nothing to change.
    private var sendStarted: Bool {
        sendStatus == .sending || sendStatus == .sent
    }

    private var savedMessage: Text {
        sendStarted
            ? Text("It stays on this Mac with the audio, and a copy is going to the developer. The whole report can be exported as a zip from Reports.")
            : Text("It stays on this Mac with the audio. Send it to the developer so it can be fixed, or export the whole report as a zip from Reports.")
    }

    /// Whether the recording goes too, on both screens until it is sent: on by default, disabled
    /// with its reason when the file is over what the endpoint takes.
    private var audioSwitch: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Include the audio")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                audioHint
                    .scaledFont(size: 12)
                    .foregroundColor(audio.isAttachable ? STheme.hint : STheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            SSwitch(isOn: $includeAudio)
                .accessibilityLabel(Text("Include the audio"))
                .disabled(!audio.isAttachable || sendStatus == .sending || sendStatus == .sent)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.advancedBg))
    }

    private var audioHint: Text {
        audio.isAttachable ? Text("Sends the recording of this dictation along with the text.")
                           : Text("Too large to attach (over 25 MB)")
    }

    private var sendTitle: LocalizedStringKey {
        includeAudio ? "Send text and audio" : "Send text to developer"
    }

    private var sentTitle: LocalizedStringKey {
        includeAudio ? "Text and audio sent" : "Text sent"
    }

    /// The settings and both transcripts, plus the audio when its switch is on. Offered after the
    /// save, so the full local report is already safe whatever the network does.
    @ViewBuilder private var sendButton: some View {
        switch sendStatus {
        case .idle:
            Button(sendTitle, action: sendToDeveloper)
                .buttonStyle(.sPrimary)
                .keyboardShortcut(.defaultAction)
        case .sending:
            Button("Sending…") {}
                .buttonStyle(.sPrimary)
                .disabled(true)
        case .sent:
            Label(sentTitle, systemImage: "checkmark")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.ok)
        case .failed:
            Button("Couldn't send — retry", action: sendToDeveloper)
                .buttonStyle(.sPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The dictation being reported, as the card keeps it: the text the user got, the engine's own
/// when the cleanup changed it, and what else goes with the report.
private struct ReportTranscriptPreview: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            text("You got", recording.transcription)
            if let original = recording.distinctOriginal {
                OriginalComparison(original: original, cleaned: recording.transcription,
                                   cleanupModel: recording.cleanupModel, lineLimit: 6)
            }
            details
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.advancedBg))
    }

    private func text(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 11, weight: .bold)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundColor(STheme.hint)
            Text(verbatim: value)
                .scaledFont(size: 14)
                .foregroundColor(STheme.textBright)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var hasAudio: Bool { FileManager.default.fileExists(atPath: recording.url.path) }

    private var details: some View {
        var parts: [Text] = []
        if let model = recording.modelUsed { parts.append(Text(verbatim: model)) }
        if recording.duration > 0 { parts.append(Text(verbatim: TextUtil.formatDuration(recording.duration))) }
        parts.append(hasAudio ? Text("Audio included") : Text("No audio kept for this one"))
        let line = parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
        return line
            .scaledFont(size: 12)
            .foregroundColor(STheme.hint)
    }
}

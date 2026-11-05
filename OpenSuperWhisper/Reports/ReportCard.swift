import SwiftUI
import OpenSuperWhisperCore

/// "Report this transcription", as a card over the main window (#168): what went wrong, an
/// optional comment, and for a wrong word or name the fix for next time, added to the dictionary
/// on the spot. The report is saved on this Mac with the audio; nothing is sent.
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

    private static let editorBaseHeight: CGFloat = 76
    private static let editorMaxHeight: CGFloat = 110

    #if DEBUG
    /// For the snapshot probe: a draft already filled in, or the card after Save.
    static var snapshotDraft: ReportDraft?
    static var snapshotSaved = false
    #endif

    init(recording: Recording, dictionaryEnabled: Binding<Bool>,
         addToDictionary: @escaping (CustomDictionaryEntry) -> Void, reports: TranscriptionReportsModel) {
        self.recording = recording
        self._dictionaryEnabled = dictionaryEnabled
        self.addToDictionary = addToDictionary
        self.reports = reports
        var draft = reports.draft(for: recording.id)
        var status = Status.editing
        #if DEBUG
        draft = Self.snapshotDraft ?? draft
        status = Self.snapshotSaved ? .saved : status
        #endif
        _draft = State(initialValue: draft)
        _status = State(initialValue: status)
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
            reports.keepDraft(draft, for: recording.id)
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
        status = .saving
        Task {
            do {
                try await reports.save(draft, for: recording)
                status = .saved
            } catch {
                status = .failed
            }
        }
    }

    /// Sends the text of the report, never the audio, to the developer. Offered once the local save
    /// is done, so the full report with its audio is already kept whatever the network does.
    private func sendToDeveloper() {
        sendStatus = .sending
        Task {
            do {
                try await DictationReportSender.send(recording: recording,
                                                     problem: draft.problem, comment: draft.comment)
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
            if draft.showsWordFields {
                wordFix
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldTitle("Comment (optional)")
                SEditor(text: $draft.comment,
                        height: min(Self.editorBaseHeight * textScale, Self.editorMaxHeight),
                        fontSize: 14, monospaced: false,
                        placeholder: "What you said, what you expected, anything that helps.")
                    .accessibilityLabel(Text("Comment (optional)"))
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

    private var footer: some View {
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
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.sSecondary)
            Button("Save report", action: save)
                .buttonStyle(.sPrimary)
                .disabled(!draft.canSave || status == .saving)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
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
                    Text("It stays on this Mac with the audio. You can send the text to the developer below, or export the whole report as a zip from Reports.")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.vertical, 28)
            HStack(spacing: 10) {
                sendButton
                Spacer(minLength: 0)
                Button("Show reports") { navigation.openReports() }
                    .buttonStyle(.sSecondary)
                Button("Done", action: close)
                    .buttonStyle(.sPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Text only: the settings and both transcripts, never the audio. Offered after the save, so
    /// the full local report is already safe whatever the network does.
    @ViewBuilder private var sendButton: some View {
        switch sendStatus {
        case .idle:
            Button("Send text to developer", action: sendToDeveloper)
                .buttonStyle(.sSecondary)
        case .sending:
            Button("Sending…") {}
                .buttonStyle(.sSecondary)
                .disabled(true)
        case .sent:
            Label("Text sent", systemImage: "checkmark")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.ok)
        case .failed:
            Button("Couldn't send — retry", action: sendToDeveloper)
                .buttonStyle(.sSecondary)
                .foregroundColor(STheme.warn)
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

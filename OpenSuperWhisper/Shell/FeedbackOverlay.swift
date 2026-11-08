import SwiftUI

/// Feedback, as a card over the main window: a bug or an idea written here and sent straight to
/// the team, an optional email for an answer, and the one line of app details the user can read
/// before it goes and switch off. GitHub and the betas stay one click away underneath.
///
/// `asked`: the app opened it itself, the one time it asks (#206). The same form, under a note
/// that says why it came up, set to a bug, with the email asked for by name: the bug hunt wants
/// a way to come back to whoever reports one.
struct FeedbackOverlay: View {
    @ObservedObject var model: FeedbackFormModel
    var asked = false
    @ObservedObject private var navigation = AppNavigation.shared
    @Environment(\.textScaleFactor) private var textScale
    @Environment(\.locale) private var locale
    @FocusState private var messageFocused: Bool

    /// The message box grows with the text size only this far, so at the largest size in a small
    /// window the switch and the line it sends stay in view above the footer.
    private static let editorBaseHeight: CGFloat = 104
    private static let editorMaxHeight: CGFloat = 130

    var body: some View {
        ModalCard(maxWidth: 600, maxHeight: 900, hugsContent: true, onClose: close) {
            VStack(spacing: 0) {
                header
                if model.status == .sent {
                    thanks
                } else {
                    // One copy of the form, scrolling only when the window is too short for it:
                    // swapping copies would rebuild the fields and lose the caret mid-sentence.
                    ScrollView { form }
                        .scrollBounceBehavior(.basedOnSize)
                    footer
                }
            }
        }
        .onAppear(perform: startOnABugWhenAsked)
        .task { await model.refreshRecentDictations() }
    }

    private func close() {
        navigation.feedbackOpen = false
    }

    private var emailLabel: LocalizedStringKey {
        asked ? "Your email, so we can follow up with you" : "Email (optional, if you'd like an answer)"
    }

    /// The bug hunt is about bugs: an asked card starts there, unless a draft already chose.
    private func startOnABugWhenAsked() {
        if asked && model.message.isEmpty { model.kind = .bug }
    }

    private func cancel() {
        model.discard()
        navigation.feedbackOpen = false
    }

    // MARK: - Layout

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if asked { askedIntro } else { title }
            Spacer(minLength: 0)
            CloseButton(action: close)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 16)
        .background(asked ? STheme.accentTint : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Send feedback")
                .scaledFont(size: 22, weight: .bold)
                .foregroundColor(STheme.textBright)
            Text("Tell us what went wrong or what you'd like. It goes straight to the team.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    /// Why the card opened on its own, in place of its usual title. No taller than two lines of
    /// text beyond it, so at the largest text size the details switch still shows under the
    /// message box.
    private var askedIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("We're hunting bugs")
                .scaledFont(size: 22, weight: .bold)
                .foregroundColor(STheme.textBright)
                .fixedSize(horizontal: false, vertical: true)
            Text("This update is all about stability. Tell us anything that goes wrong, even something small, and leave your email so we can follow up with you.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            SSegmented(selection: $model.kind, options: [
                (FeedbackKind.bug, "Report a bug"),
                (FeedbackKind.idea, "Share an idea"),
            ])
            .disabled(!model.isEditable)
            messageField
            // Right under the message, before the optional email: at the largest text size in a
            // small window, what goes with the message is still in view above Send. The audio
            // row follows, nothing attached by default so a single line, for the same reason.
            detailsRow
            audioRow
            VStack(alignment: .leading, spacing: 6) {
                Text(emailLabel)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                // Not an address as the prompt: a localized key turns one into a blue link.
                STextField("Only used to answer you", text: $model.email, width: nil)
                    .disabled(!model.isEditable)
            }
            otherWays
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

    private var messageField: some View {
        VStack(alignment: .trailing, spacing: 6) {
            SEditor(text: $model.message,
                    height: min(Self.editorBaseHeight * textScale, Self.editorMaxHeight),
                    fontSize: 14, monospaced: false,
                    placeholder: model.kind == .bug
                        ? "What happened, and what did you expect?"
                        : "What would make OpenSuperWhisper better for you?")
                .focused($messageFocused)
                .disabled(!model.isEditable)
                .accessibilityLabel(Text("Message"))
                .onAppear {
                    // Once the card has laid the editor out, or the focus request is dropped.
                    DispatchQueue.main.async { messageFocused = true }
                }
            if model.showsCounter {
                Text(verbatim: "\(count(model.messageLength)) / \(count(FeedbackSender.maxMessageLength))")
                    .scaledFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundColor(model.messageLength > FeedbackSender.maxMessageLength
                                     ? STheme.warn : STheme.hint)
            }
        }
    }

    private var detailsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Include app details")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Text(verbatim: model.details)
                    .scaledFont(size: 12)
                    .foregroundColor(model.includeDetails ? STheme.hint : STheme.faint)
                    .strikethrough(!model.includeDetails, color: STheme.faint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(disclosureText)
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            SSwitch(isOn: $model.includeDetails)
                .accessibilityLabel(Text("Include app details"))
                .disabled(!model.isEditable)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.advancedBg))
    }

    private var pickerTitle: LocalizedStringKey { model.isPickingAudio ? "Close" : "Choose…" }

    private var disclosureText: LocalizedStringKey {
        switch model.disclosure {
        case .textOnly: "Nothing else is sent: no dictations, audio, logs or settings."
        case .withRecording: "The recording you attached is sent too. Nothing else: no other dictations, logs or settings."
        }
    }

    // MARK: - Attached audio

    private var audioRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attach a dictation's audio")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text("Optional. Pick a recent dictation so we can reproduce a transcription problem.")
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if model.attachedAudio == nil {
                    Button(pickerTitle) { model.isPickingAudio.toggle() }
                        .buttonStyle(.sSecondary)
                        .disabled(!model.isEditable)
                }
            }
            if let audio = model.attachedAudio {
                attachedChip(audio)
            } else if model.isPickingAudio {
                audioPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.advancedBg))
    }

    private func attachedChip(_ audio: DictationAudioChoice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(STheme.accent)
            audioLabel(audio, detail: audioSizeDetail(audio))
            Spacer(minLength: 0)
            Button { model.detachAudio() } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundColor(STheme.hint)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isEditable)
            .accessibilityLabel(Text("Remove the attached recording"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.cardBg))
    }

    private var audioPicker: some View {
        Group {
            if model.recentDictations.isEmpty {
                Text("No recent dictations to attach.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.recentDictations) { audioPickerRow($0) }
                    }
                }
                .frame(maxHeight: 190 * textScale)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func audioPickerRow(_ audio: DictationAudioChoice) -> some View {
        Button { model.attach(audio) } label: {
            HStack(spacing: 12) {
                audioLabel(audio, detail: audioDetail(audio))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!audio.isAttachable)
        .opacity(audio.isAttachable ? 1 : 0.55)
    }

    private func audioDetail(_ audio: DictationAudioChoice) -> Text {
        switch audio.eligibility {
        case .eligible: audioSizeDetail(audio)
        case .tooLarge: Text("Too large to attach (over 25 MB)")
        case .noAudio: Text("No audio kept for this dictation")
        }
    }

    private func audioLabel(_ audio: DictationAudioChoice, detail: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(audio.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))) · \(audio.preview)")
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(STheme.textBright)
                .lineLimit(1)
            detail
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
        }
    }

    private func audioSizeDetail(_ audio: DictationAudioChoice) -> Text {
        let size = ByteCountFormatter.string(fromByteCount: Int64(audio.fileSize ?? 0), countStyle: .file)
        return Text(verbatim: "\(TextUtil.formatDuration(audio.duration)) · \(size)")
    }

    /// The ways out of the app this card replaced, for those who would rather use them.
    private var otherWays: some View {
        FlowLayout(spacing: 6) {
            Text("Prefer GitHub?")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
            linkButton("Open an issue", url: FeedbackLink.newIssue)
            Text(verbatim: "·")
                .scaledFont(size: 12)
                .foregroundColor(STheme.faint)
            linkButton("Try a beta build", url: FeedbackLink.betaBuilds)
        }
    }

    private func linkButton(_ title: LocalizedStringKey, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(STheme.accent)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusLine
                .layoutPriority(1)
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.sSecondary)
                .disabled(!model.isEditable)
            Button("Send") { Task { await model.send() } }
                .buttonStyle(.sPrimary)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.status == .sending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending…")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
            }
        } else if let problem = model.limitProblem {
            switch problem {
            case .messageTooLong: warning("Too long to send. Shorten it, or open an issue on GitHub.")
            case .emailTooLong: warning("That email address is too long.")
            }
        } else if model.status == .audioFailed {
            warning("The recording couldn't be sent. Remove it, or try again later.")
        } else if model.status == .refused {
            warning("It was turned down as it is. Shorten it, or open an issue on GitHub.")
        } else if model.status == .failed {
            warning("Couldn't send it. Check your connection and try again.")
        }
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .scaledFont(size: 13, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 13)
        }
        .foregroundColor(STheme.warn)
    }

    private func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 26)
                    .foregroundColor(STheme.ok)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thanks! It reached us. 🍌")
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundColor(STheme.textBright)
                    Text("We read every message. If you left an email, the answer will come there.")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.vertical, 28)
            HStack {
                Spacer(minLength: 0)
                Button("Close", action: close)
                    .buttonStyle(.sPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

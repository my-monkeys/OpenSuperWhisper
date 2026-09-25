import SwiftUI

/// Walks someone through reading a few sentences so the app learns how *they* say punctuation.
///
/// Nothing is shown while they read. Live transcription is approximate, so a highlight following
/// along would jump and backtrack, and watching it fail is worse than watching nothing. The
/// comparison happens once the clip is in.
struct PunctuationCalibrationView: View {
    /// Rules the user accepted, handed back to the dictionary editor.
    let onFinish: ([CustomDictionaryEntry]) -> Void
    let onCancel: () -> Void

    @StateObject private var model = PunctuationCalibrationModel()
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(STheme.border)

            Group {
                switch model.stage {
                // Scrolls only when the sentence does not fit, at a large text size. The sheet
                // keeps one height, so the button read for every sentence stays where it is,
                // and the header and footer stay in view.
                case .reading:
                    ViewThatFits(in: .vertical) {
                        reading
                        ScrollView { reading.padding(.top, 18) }
                    }
                case .working: working
                case .review: review
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(STheme.border)
            footer
        }
        .frame(width: 640, height: 460)
        .background(STheme.windowBg)
        .onAppear { model.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Teach it your punctuation")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Text(model.stage == .review
                     ? "Keep the ones that look right"
                     : "Read each sentence aloud, punctuation and all")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
            }
            Spacer()
            if model.stage != .review {
                Text("\(model.index + 1) of \(model.sentences.count)")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(STheme.hint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Reading

    private var reading: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(model.currentSentence?.text ?? "")
                .scaledFont(size: 26, weight: .medium, design: .serif)
                .foregroundColor(STheme.textBright)
                .multilineTextAlignment(.center)
                .lineSpacing(8)
                // Every line, always: this is the sentence to read aloud, and at a large text
                // size it used to lose its last line.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 44)
                .textSelection(.enabled)

            Text(model.isRecording
                 ? "Listening. Press stop when you reach the end."
                 : "Say the punctuation the way you normally would.")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)

            Button(action: model.toggleRecording) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isRecording ? Color.red : STheme.accent)
                        .frame(width: 9 * textScale, height: 9 * textScale)
                    Text(model.isRecording ? "Stop" : "Read this one")
                        .scaledFont(size: 13, weight: .semibold)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(STheme.controlBg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(STheme.controlBorder))
            }
            .buttonStyle(.plain)

            Spacer()

            progressDots
        }
        .padding(.bottom, 18)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.sentences.enumerated()), id: \.element.id) { position, _ in
                Circle()
                    .fill(position < model.index ? STheme.accent
                          : position == model.index ? STheme.accent.opacity(0.45)
                          : STheme.border)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Working

    private var working: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text("Reading it back…")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
        }
    }

    // MARK: - Review

    private var review: some View {
        Group {
            if model.proposals.isEmpty {
                VStack(spacing: 10) {
                    Text("Nothing to learn from that")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text("The punctuation came back already written, so there was nothing standing in for it. That usually means the model is doing it for you.")
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($model.proposals) { $proposal in
                            proposalRow($proposal)
                            Divider().overlay(STheme.border)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func proposalRow(_ proposal: Binding<PunctuationCalibrationModel.Proposal>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: proposal.keep).labelsHidden()

            Text(proposal.wrappedValue.entry.replacement)
                .scaledFont(size: 17, weight: .semibold, design: .serif)
                .foregroundColor(STheme.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.wrappedValue.entry.triggers.joined(separator: ", "))
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.text)
                Text(proposal.wrappedValue.example)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundColor(STheme.hint)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundColor(STheme.hint)

            Spacer()

            if model.stage == .reading && model.index > 0 {
                Button("Skip the rest") { model.finishEarly() }
                    .buttonStyle(.plain)
                    .foregroundColor(STheme.hint)
            }

            if model.stage == .review {
                Button {
                    onFinish(model.acceptedEntries)
                } label: {
                    Text(model.acceptedEntries.isEmpty ? "Done" : "Add \(model.acceptedEntries.count) rules")
                        .scaledFont(size: 13, weight: .semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(STheme.accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .scaledFont(size: 12)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

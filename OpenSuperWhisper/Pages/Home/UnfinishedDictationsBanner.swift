import SwiftUI

/// Dictations that never became text, and the text of the ones recovered this session. Sits above
/// the feed and disappears once there is nothing left to offer.
struct UnfinishedDictationsBanner: View {
    @ObservedObject var model: UnfinishedDictations

    var body: some View {
        if !model.clips.isEmpty || !model.recovered.isEmpty || model.transcribing > 0 {
            VStack(alignment: .leading, spacing: 12) {
                if !model.clips.isEmpty || model.transcribing > 0 { clipsSection }
                ForEach(Array(model.recovered.enumerated()), id: \.offset) { index, text in
                    recoveredRow(text, index: index)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.warnBg))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(STheme.warnBorder, lineWidth: 1))
        }
    }

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    Text("Kept \(UnfinishedDictations.retentionDays) days")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.transcribing > 0 {
                    ProgressView().controlSize(.small)
                }
                if model.clips.count > 1 {
                    Button("Discard all") { model.discardAll() }
                        .buttonStyle(.sSecondary)
                }
            }
            ForEach(model.clips) { clip in
                clipRow(clip)
            }
        }
    }

    @ViewBuilder private var title: some View {
        let count = model.clips.count + model.transcribing
        Group {
            if count == 1 {
                Text("1 unfinished dictation")
            } else {
                Text("\(count) unfinished dictations")
            }
        }
        .scaledFont(size: 15, weight: .semibold)
        .foregroundColor(STheme.warn)
    }

    private func clipRow(_ clip: UnfinishedClip) -> some View {
        HStack(spacing: 10) {
            Text(clip.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(STheme.text)
            Text(Self.length(clip.duration))
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button("Discard") { model.discard(clip) }
                .buttonStyle(.sSecondary)
            Button("Transcribe") { model.recover(clip) }
                .buttonStyle(.sPrimary)
        }
    }

    private func recoveredRow(_ text: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(STheme.text)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") { model.copy(text) }
                .buttonStyle(.sSecondary)
            Button("Dismiss") { model.dismissRecovered(at: index) }
                .buttonStyle(.sQuiet)
        }
    }

    static func length(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

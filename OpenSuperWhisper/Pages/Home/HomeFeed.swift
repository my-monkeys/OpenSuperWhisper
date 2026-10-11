import SwiftUI
import OpenSuperWhisperCore

/// The dictations, newest first, under a header per day (TODAY, YESTERDAY, then the date).
struct HomeFeed: View {
    @ObservedObject var viewModel: ContentViewModel
    let searchQuery: String
    let trigger: HomeTriggerSummary?
    @Environment(\.appTextScale) private var textScale
    @State private var width: CGFloat = 0

    /// Below this width (at the designed text size) the row actions leave their own column.
    private static let compactWidth: CGFloat = 600

    private struct Day: Identifiable {
        let start: Date
        var recordings: [Recording]
        var id: Date { start }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for recording in viewModel.recordings {
            let start = calendar.startOfDay(for: recording.timestamp)
            if days.last?.start == start {
                days[days.count - 1].recordings.append(recording)
            } else {
                days.append(Day(start: start, recordings: [recording]))
            }
        }
        return days
    }

    var body: some View {
        if viewModel.recordings.isEmpty {
            if !viewModel.isLoadingMore {
                emptyState
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days) { day in
                    DayHeader(day: day.start)
                    ForEach(day.recordings) { recording in
                        row(recording)
                    }
                }
                if viewModel.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        }
    }

    private func row(_ recording: Recording) -> some View {
        FeedRow(
            recording: recording,
            searchQuery: searchQuery,
            compact: width < Self.compactWidth * textScale,
            onDelete: { viewModel.deleteRecording(recording) },
            onRegenerate: { model in
                Task { await TranscriptionQueue.shared.requeueRecording(recording, model: model) }
            }
        )
        .id(recording.id)
        .onAppear {
            if recording.id == viewModel.recordings.last?.id {
                viewModel.loadMore()
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !searchQuery.isEmpty {
            FeedEmptyState(symbol: "magnifyingglass", title: "No results",
                           detail: Text("Nothing you dictated matches “\(searchQuery)”."))
        } else if viewModel.filter != .all {
            FeedEmptyState(symbol: "line.3.horizontal.decrease", title: filterEmptyTitle,
                           detail: Text("Other recordings are under All.")) {
                Button("Show all") { viewModel.setFilter(.all) }
                    .buttonStyle(.sSecondary)
            }
        } else {
            FeedEmptyState(symbol: "waveform", title: "No dictations yet", detail: firstDictationHint)
        }
    }

    private var filterEmptyTitle: LocalizedStringKey {
        switch viewModel.filter {
        case .dictations: return "No dictations here"
        case .files: return "No imported files"
        case .errors: return "No failed transcriptions"
        case .all: return "No dictations yet"
        }
    }

    private var firstDictationHint: Text {
        guard let trigger else {
            return Text("Press the record button below, or set a shortcut in Settings to dictate from any app.")
        }
        return trigger.holds
            ? Text("Hold \(trigger.label) in any app, or press the record button below. Drop an audio file here to transcribe it.")
            : Text("Press \(trigger.label) in any app, or the record button below. Drop an audio file here to transcribe it.")
    }
}

private struct DayHeader: View {
    let day: Date

    var body: some View {
        label
            .scaledFont(size: 12, weight: .bold)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundColor(STheme.hint)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var label: Text {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return Text("Today") }
        if calendar.isDateInYesterday(day) { return Text("Yesterday") }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return Text(day, format: .dateTime.weekday(.wide).month(.wide).day())
        }
        return Text(day, format: .dateTime.month(.wide).day().year())
    }
}

private struct FeedEmptyState<Action: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: Text
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .scaledFont(size: 22)
                .foregroundColor(STheme.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(STheme.accentSoft))
            Text(title)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundColor(STheme.textBright)
                .padding(.top, 4)
            detail
                .scaledFont(size: 14)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 32)
    }
}

extension FeedEmptyState where Action == EmptyView {
    init(symbol: String, title: LocalizedStringKey, detail: Text) {
        self.init(symbol: symbol, title: title, detail: detail, action: { EmptyView() })
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenSuperWhisperCore

/// The saved reports, as a card over Home (#168). Each one can become a GitHub issue, opened in
/// the browser with its texts filled in; all of them export as one zip with the audio. Both are
/// things the user does: nothing here leaves the Mac by itself.
struct ReportsCard: View {
    @ObservedObject var reports: TranscriptionReportsModel
    @ObservedObject private var navigation = AppNavigation.shared

    private enum ExportState: Equatable {
        case idle, exporting, done(fileName: String), failed
    }

    @State private var exportState = ExportState.idle
    @State private var pendingDelete: TranscriptionReport?

    var body: some View {
        ModalCard(maxWidth: 680, maxHeight: 760, hugsContent: true, onClose: close) {
            VStack(spacing: 0) {
                header
                if reports.reports.isEmpty {
                    empty
                } else {
                    ScrollView { list }
                        .scrollBounceBehavior(.basedOnSize)
                }
                footer
            }
        }
        .confirmationDialog("Delete this report?", isPresented: deleteDialogShown, titleVisibility: .visible,
                            presenting: pendingDelete) { report in
            Button("Delete", role: .destructive) { Task { await reports.delete(report) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its copy of the audio goes with it. The dictation stays in your history.")
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func close() {
        navigation.reportsOpen = false
    }

    // MARK: - Layout

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Reports")
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text("Dictations you flagged, kept on this Mac. Share them when you're ready.")
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

    private var empty: some View {
        Text("No reports yet. Flag a dictation from its row on Home.")
            .scaledFont(size: 14)
            .foregroundColor(STheme.hint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.vertical, 28)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(reports.reports) { report in
                ReportRow(report: report, onDelete: { pendingDelete = report })
                    .overlay(alignment: .top) {
                        if report.id != reports.reports.first?.id {
                            Rectangle().fill(STheme.border).frame(height: 1)
                        }
                    }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text("The zip holds the audio and both texts of every report. A GitHub issue opens in your browser through a link that carries the texts, never the audio; nothing is posted until you submit it there.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Button("Export as zip…", action: export)
                    .buttonStyle(.sPrimary)
                    .disabled(reports.reports.isEmpty || exportState == .exporting)
            }
            exportStatus
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    @ViewBuilder private var exportStatus: some View {
        switch exportState {
        case .idle:
            EmptyView()
        case .exporting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the zip…").scaledFont(size: 13).foregroundColor(STheme.hint)
            }
        case .done(let fileName):
            Label { Text("Saved \(fileName)") } icon: { Image(systemName: "checkmark.circle.fill") }
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(STheme.ok)
        case .failed:
            Label { Text("Couldn't write the zip.") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(STheme.warn)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TranscriptionReportArchive.suggestedName(exportedAt: Date()) + ".zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportState = .exporting
        Task {
            do {
                try await reports.export(to: url)
                exportState = .done(fileName: url.lastPathComponent)
            } catch {
                exportState = .failed
            }
        }
    }
}

/// One report: what went wrong, the text it got, the comment, when and with what, and its two
/// actions.
private struct ReportRow: View {
    let report: TranscriptionReport
    let onDelete: () -> Void
    @State private var showsOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                SBadge(report.problem.label, kind: .new)
                Spacer(minLength: 8)
                actions
            }
            Text(verbatim: report.finalText)
                .scaledFont(size: 14)
                .foregroundColor(STheme.textBright)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !report.comment.isEmpty {
                Text(verbatim: report.comment)
                    .scaledFont(size: 13)
                    .italic()
                    .foregroundColor(STheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                meta
                if report.distinctRawText != nil {
                    FeedRowOriginalToggle(isShown: $showsOriginal)
                }
            }
            if showsOriginal, let original = report.distinctRawText {
                FeedRowOriginalText(original: original, cleaned: report.finalText, cleanupModel: nil)
            }
        }
        .padding(.vertical, 14)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(ReportIssueLink.url(for: report))
            } label: {
                Label("GitHub issue", systemImage: "arrow.up.right")
            }
            .buttonStyle(.sSecondary)
            .help("Open a new GitHub issue in your browser. The link it opens carries this report's texts.")
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.sSecondary)
            .help("Delete")
            .accessibilityLabel(Text("Delete"))
        }
        .fixedSize()
    }

    private var meta: some View {
        var parts = [Text(report.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())]
        if let model = report.modelUsed {
            parts.append(report.wasFallback ? Text(verbatim: model).foregroundColor(STheme.warn) : Text(verbatim: model))
        }
        if let shouldBe = report.shouldBe { parts.append(Text("Should be “\(shouldBe)”")) }
        parts.append(report.audioFileName == nil ? Text("No audio") : Text("Audio kept"))
        let line = parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
        return line
            .scaledFont(size: 12)
            .foregroundColor(STheme.hint)
            .lineLimit(2)
    }
}

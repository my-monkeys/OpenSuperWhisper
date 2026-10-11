import SwiftUI
import OpenSuperWhisperCore

/// The chips that narrow the feed, how long the history is kept, and the microphone and
/// delete-all controls that used to sit beside the record button.
struct HomeFilterBar: View {
    @ObservedObject var viewModel: ContentViewModel
    @State private var showDeleteConfirmation = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                chips
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 10) {
                chips
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 10) {
            chip(.all, Text("All"))
            chip(.dictations, Text("Dictations"))
            chip(.files, Text("Files"))
            chip(.errors, viewModel.failedCount > 0 ? Text("Errors · \(viewModel.failedCount)") : Text("Errors"))
        }
        .fixedSize()
    }

    private func chip(_ filter: RecordingFilter, _ label: Text) -> some View {
        SFilterChip(label: label, selected: viewModel.filter == filter) {
            viewModel.setFilter(filter)
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            RetentionSummary()
            MicrophonePickerIconView(microphoneService: viewModel.microphoneService)
            deleteAllButton
        }
        .fixedSize()
    }

    /// Trash-everything control with its confirmation dialog.
    @ViewBuilder private var deleteAllButton: some View {
        if !viewModel.recordings.isEmpty {
            Button {
                showDeleteConfirmation = true
            } label: {
                HomeIconButtonLabel(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete all recordings")
            .confirmationDialog(
                "Delete All Recordings",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    viewModel.deleteAllRecordings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete all recordings? This action cannot be undone.")
            }
            .interactiveDismissDisabled()
        }
    }
}

/// The small square icon button of the filter row.
struct HomeIconButtonLabel: View {
    let systemName: String
    @State private var hovered = false

    var body: some View {
        Image(systemName: systemName)
            .scaledFont(size: 13)
            .foregroundColor(hovered ? STheme.textBright : STheme.hint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? STheme.fill : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @State private var showMenu = false

    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }

    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }

    var body: some View {
        Button {
            showMenu.toggle()
        } label: {
            HomeIconButtonLabel(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic")
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? String(localized: "Select microphone"))
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No microphones available")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .padding()
                } else {
                    ForEach(builtInMicrophones) { microphoneRow($0) }
                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(externalMicrophones) { microphoneRow($0) }
                }
            }
            .frame(minWidth: 220)
            .padding(.vertical, 8)
        }
    }

    private func microphoneRow(_ microphone: MicrophoneService.AudioDevice) -> some View {
        Button {
            microphoneService.selectMicrophone(microphone)
            showMenu = false
        } label: {
            HStack {
                Text(microphone.displayName)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let current = microphoneService.currentMicrophone, current.id == microphone.id {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundColor(STheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

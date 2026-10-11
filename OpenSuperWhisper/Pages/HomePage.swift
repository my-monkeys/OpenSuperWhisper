import SwiftUI
import OpenSuperWhisperCore

/// Home: the greeting and the state of dictation at the top, the feed of everything dictated
/// below, the record button floating over it. Replaces the old Transcriptions view.
struct HomePage: View {
    @StateObject private var viewModel = ContentViewModel()
    @EnvironmentObject private var permissions: PermissionsManager
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var transcription = TranscriptionService.shared
    @State private var debouncedSearchText = ""
    @State private var searchTask: Task<Void, Never>?

    /// Room under the last row so the floating control never covers it.
    private static let floatingControlClearance: CGFloat = 150

    var body: some View {
        HomeTriggerReader { trigger in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HomePermissionBanners(permissions: permissions)
                        HomeGreeting(trigger: trigger)
                        HomeSummaryTiles(trigger: trigger)
                        HomeFilterBar(viewModel: viewModel)
                            .padding(.top, 4)
                        HomeFeed(viewModel: viewModel, searchQuery: debouncedSearchText, trigger: trigger)
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 26)
                    .padding(.bottom, Self.floatingControlClearance)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.recordings.count)
                bottomFade
                HomeRecordControl(viewModel: viewModel, trigger: trigger)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(STheme.windowBg)
        .overlay { modelLoadingOverlay }
        .onAppear {
            if navigation.searchText.isEmpty {
                viewModel.loadInitialData()
            } else {
                performSearch(navigation.searchText)
            }
        }
        .onChange(of: navigation.searchText) { _, text in
            performSearch(text)
        }
        .onChange(of: viewModel.shouldClearSearch) { _, shouldClear in
            guard shouldClear else { return }
            searchTask?.cancel()
            debouncedSearchText = ""
            navigation.searchText = ""
            viewModel.shouldClearSearch = false
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let progress = userInfo["progress"] as? Float,
                  let status = userInfo["status"] as? RecordingStatus else { return }
            viewModel.handleProgressUpdate(
                id: id,
                transcription: userInfo["transcription"] as? String,
                progress: progress,
                status: status,
                isRegeneration: userInfo["isRegeneration"] as? Bool,
                modelUsed: userInfo["modelUsed"] as? String,
                wasFallback: userInfo["wasFallback"] as? Bool
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.reload()
        }
    }

    /// The feed fades out under the floating control instead of being cut mid-line.
    private var bottomFade: some View {
        LinearGradient(colors: [STheme.windowBg.opacity(0), STheme.windowBg.opacity(0.9), STheme.windowBg],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 72)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var modelLoadingOverlay: some View {
        let permissionsGranted = permissions.isMicrophonePermissionGranted
            && permissions.isAccessibilityPermissionGranted
        if transcription.isLoading && permissionsGranted {
            ZStack {
                STheme.scrim
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text(AppPreferences.shared.selectedEngine == "fluidaudio"
                         ? "Loading Parakeet Model..."
                         : "Loading Whisper Model...")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(STheme.cardBg))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(STheme.border, lineWidth: 1))
            }
            .ignoresSafeArea()
        }
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        if query.isEmpty {
            debouncedSearchText = ""
            viewModel.search(query: "")
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedSearchText = query
                viewModel.search(query: query)
            }
        }
    }
}

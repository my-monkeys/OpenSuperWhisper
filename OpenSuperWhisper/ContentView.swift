//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import OpenSuperWhisperCore

@MainActor
class ContentViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var transcriptionQueue = TranscriptionQueue.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var recordings: [Recording] = []
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var microphoneService = MicrophoneService.shared
    @Published var shouldClearSearch = false
    @Published var errorMessage: String?
    /// Which kind of recording the feed lists (Home's chips).
    @Published private(set) var filter: RecordingFilter = .all
    /// Failed recordings across the whole history, for the Errors chip.
    @Published private(set) var failedCount = 0

    private var currentPage = 0
    private let pageSize = 100
    private var currentSearchQuery = ""
    /// Bumped on every full reload so an in-flight load started before a reload
    /// (e.g. just before a retention prune) discards its now-stale results.
    private var loadGeneration = 0
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var errorDismissTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Local keyDown monitor for Esc-to-cancel while a main-window recording is live.
    private var escapeMonitor: Any?
    
    init() {
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting && self.state != .decoding {
                    self.state = .connecting
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording && self.state != .decoding {
                    self.state = .recording
                    self.startBlinking()
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    self.state = .idle
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
    }
    
    func loadInitialData() {
        startFreshLoad(query: "")
    }

    /// Resets paging and starts a fresh page-0 load. Bumps the load generation so
    /// any in-flight load discards its stale results instead of overwriting the
    /// list, and clears `isLoadingMore` so the reload is never dropped by the
    /// in-flight guard.
    private func startFreshLoad(query: String) {
        refreshFailedCount()
        currentSearchQuery = query
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadGeneration += 1
        isLoadingMore = false
        loadMore()
    }

    func loadMore() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true
        
        // Capture current state for async task
        let generation = loadGeneration
        let page = currentPage
        let limit = pageSize
        let query = currentSearchQuery
        let filter = filter
        let offset = page * limit
        
        
        Task {
            let newRecordings: [Recording]
            if filter != .all {
                newRecordings = (try? await recordingStore.fetchRecordings(filter: filter, query: query, limit: limit, offset: offset)) ?? []
            } else if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
            }
            
            
            await MainActor.run {
                // Discard results once a newer reload (e.g. after a retention
                // prune) has superseded this load, so stale rows never overwrite
                // the freshly reloaded list.
                guard generation == self.loadGeneration else { return }
                self.isLoadingMore = false

                if page == 0 {
                    self.recordings = newRecordings
                } else {
                    self.recordings.append(contentsOf: newRecordings)
                }
                
                if newRecordings.count < limit {
                    self.canLoadMore = false
                } else {
                    self.currentPage += 1
                }
            }
        }
    }
    
    func search(query: String) {
        startFreshLoad(query: query)
    }

    func setFilter(_ newFilter: RecordingFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        startFreshLoad(query: currentSearchQuery)
    }

    /// Reloads from the first page, keeping the search and the filter.
    func reload() {
        startFreshLoad(query: currentSearchQuery)
    }

    private func refreshFailedCount() {
        Task {
            let count = await recordingStore.countRecordings(filter: .errors)
            await MainActor.run { self.failedCount = count }
        }
    }
    
    func handleProgressUpdate(id: UUID, transcription: String?, progress: Float, status: RecordingStatus, isRegeneration: Bool?, modelUsed: String? = nil, wasFallback: Bool? = nil) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let transcription = transcription {
                recordings[index].transcription = transcription
            }
            recordings[index].progress = progress
            recordings[index].status = status
            if let isRegeneration = isRegeneration {
                recordings[index].isRegeneration = isRegeneration
            }
            if let modelUsed {
                recordings[index].modelUsed = modelUsed
            }
            if let wasFallback {
                recordings[index].wasFallback = wasFallback
            }
        }
        if status == .failed || status == .completed {
            refreshFailedCount()
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        recordingStore.deleteRecording(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
        }
    }
    
    func deleteAllRecordings() {
        recordingStore.deleteAllRecordings()
        recordings.removeAll()
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    func showError(_ message: String) {
        errorMessage = message
        errorDismissTimer?.invalidate()
        errorDismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.errorMessage = nil
            }
        }
    }

    func startRecording() {
        // Arm Esc-to-cancel for this main-window recording via a LOCAL key monitor: the
        // global `.escape` shortcut is unreliable while our own window is frontmost, and a
        // local monitor also needs no Input-Monitoring grant. Removed again on stop/cancel.
        installEscapeMonitor()

        // Capture where the dictation is happening (frontmost app + browser site) and
        // apply any context-aware model rule before the engine spins up. See F2.
        RecordingContext.shared.captureFrontmost()
        ContextModelSwitcher.applyForCurrentContext()

        if microphoneService.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            stopBlinking()
            stopDurationTimer()
            recordingDuration = 0
        } else {
            state = .recording
            startBlinking()
            recordingStartTime = Date()
            recordingDuration = 0
            startDurationTimerIfNeeded()
        }
        
        Task.detached { [recorder] in
            recorder.startRecording()
        }
    }

    /// Discard the in-progress main-window recording (Esc): throw the audio away instead
    /// of transcribing it, and return to idle. No-op unless a recording is actually live.
    func cancelRecording() {
        guard state == .recording || state == .connecting else { return }
        removeEscapeMonitor()
        recorder.cancelRecording()
        stopBlinking()
        stopDurationTimer()
        recordingDuration = 0
        state = .idle
    }

    /// Local key monitor that cancels the recording on the configured cancel shortcut
    /// (default: plain Esc). Local — fires while our window is key, no permission needed.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.state == .recording || self.state == .connecting else { return event }
            guard let shortcut = KeyboardShortcuts.getShortcut(for: .escape), let key = shortcut.key,
                  Int(event.keyCode) == key.rawValue,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == shortcut.modifiers
            else { return event }
            self.cancelRecording()
            return nil  // swallow the key (no system beep / propagation)
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    func startDecoding() {
        removeEscapeMonitor()
        state = .decoding
        stopBlinking()
        stopDurationTimer()

        IndicatorWindowManager.shared.hide()

        if let tempURL = recorder.stopRecording().url {
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    print("start decoding...")
                    let rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    let cleanedText = AppPreferences.shared.cleanTranscription(rawText)
                    // Optional LLM cleanup (no-op when disabled; returns the raw text on failure).
                    // App-aware formatting keys off the app captured at record-start, not the
                    // frontmost app: recording from the main window makes OSW itself frontmost, so
                    // asking the workspace here would never match a profile.
                    let text = await LLMPostProcessor.process(
                        cleanedText, bundleID: RecordingContext.shared.bundleID,
                        translating: AppPreferences.shared.translateToEnglish)

                    if AppPreferences.shared.saveTranscriptionHistory {
                        // Capture the current recording duration
                        let duration = await MainActor.run { self.recordingDuration }

                        // Create a new Recording instance
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
                        let finalURL = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: duration,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        ).url

                        // Move the temporary recording to final location
                        try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)

                        // Source context captured at record-start.
                        let ctx = RecordingContext.shared

                        // Save the recording to store
                        await MainActor.run {
                            // The model that actually produced the text (the local fallback,
                            // not the configured remote model, when the server was unreachable).
                            let modelUsed = TranscriptionService.shared.lastUsedModel?.displayName
                                ?? ModelCatalog.activeOption()?.displayName
                            let wasFallback = TranscriptionService.shared.lastUsedFallback
                            let newRecording = Recording(
                                id: recordingId,
                                timestamp: timestamp,
                                fileName: fileName,
                                transcription: text,
                                duration: self.recordingDuration,
                                status: .completed,
                                progress: 1.0,
                                sourceFileURL: nil,
                                sourceAppName: ctx.appName,
                                sourceWindowTitle: ctx.windowTitle,
                                sourceURL: ctx.fullURL,
                                modelUsed: modelUsed,
                                wasFallback: wasFallback
                            )
                            self.recordingStore.addRecording(newRecording)

                            // Clear search and show the new recording
                            if !self.currentSearchQuery.isEmpty {
                                self.shouldClearSearch = true
                                self.currentSearchQuery = ""
                            }
                            self.recordings.insert(newRecording, at: 0)
                        }
                    } else {
                        // Delete the temporary recording immediately
                        try? FileManager.default.removeItem(at: tempURL)
                    }

                    print("Transcription result: \(text)")
                } catch {
                    print("Error transcribing audio: \(error)")
                    // Preserve temp recording so user can retry
                    await MainActor.run {
                        self.showError("Transcription failed")
                    }
                }

                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            }
        } else {
            state = .idle
            recordingDuration = 0
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }
    
    private func startDurationTimerIfNeeded() {
        guard durationTimer == nil else { return }
        if recordingStartTime == nil {
            recordingStartTime = Date()
            recordingDuration = 0
        }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let startTime = Date()
            Task { @MainActor in
                if let recordingStartTime = self.recordingStartTime {
                    self.recordingDuration = startTime.timeIntervalSince(recordingStartTime)
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }
}

/// The history as the old settings window's Transcriptions tab embeds it. That window is on its
/// way out; the main window shows `HomePage` through `AppShellView`, which provides the
/// permissions itself.
struct ContentView: View {
    @StateObject private var permissions = PermissionsManager()

    var body: some View {
        HomePage()
            .environmentObject(permissions)
    }
}

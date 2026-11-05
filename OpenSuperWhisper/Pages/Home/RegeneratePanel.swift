import SwiftUI
import OpenSuperWhisperCore

/// The panel behind the small chevron next to the regenerate button (#276): transcribe the audio
/// again with a model, or rerun only the AI cleanup on the text the engine produced.
struct RegeneratePanel: View {
    enum Tab: Hashable { case audio, cleanup }

    let recording: Recording
    let models: [RegenerationModel]
    let backends: [CleanupBackendOption]
    let hasAudio: Bool
    let cleanupAvailable: Bool
    let onRegenerate: (DictationModelOption?) -> Void
    let onCleanup: (HistoryRestyle.Request) -> Void
    let onClose: () -> Void

    @Environment(\.appTextScale) private var textScale
    @State private var tab: Tab
    @State private var backendTag: String
    @State private var model: String
    @State private var style: WritingStyle
    @State private var extraInstruction = ""

    @MainActor
    init(recording: Recording, tab: Tab? = nil, models: [RegenerationModel] = RegenerationModels.current(),
         backends: [CleanupBackendOption]? = nil,
         hasAudio: Bool? = nil, cleanupAvailable: Bool? = nil,
         onRegenerate: @escaping (DictationModelOption?) -> Void = { _ in },
         onCleanup: @escaping (HistoryRestyle.Request) -> Void = { _ in },
         onClose: @escaping () -> Void = {}) {
        let hasAudio = hasAudio ?? FileManager.default.fileExists(atPath: recording.url.path)
        self.recording = recording
        self.models = models
        let backends = backends ?? CleanupBackendOptions.current()
        self.backends = backends
        self.hasAudio = hasAudio
        self.cleanupAvailable = cleanupAvailable ?? HistoryRestyle.isAvailable(for: recording)
        self.onRegenerate = onRegenerate
        self.onCleanup = onCleanup
        self.onClose = onClose
        _tab = State(initialValue: tab ?? (hasAudio ? .audio : .cleanup))
        let tag = CleanupBackendOptions.defaultTag(firstModel: recording.cleanupModel,
                                                   current: AppPreferences.shared.aiBackend, in: backends)
        _backendTag = State(initialValue: tag ?? "")
        _model = State(initialValue: backends.first { $0.tag == tag }?.configuredModel ?? "")
        let styles = WritingStyle.builtIns + AppPreferences.shared.customWritingStyles
        _style = State(initialValue: styles.first { WritingStyleText.name($0) == recording.styleUsed } ?? .raw)
    }

    private var backend: CleanupBackendOption? { backends.first { $0.tag == backendTag } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasAudio {
                Picker("", selection: $tab) {
                    Text("Audio").tag(Tab.audio)
                    Text("AI cleanup").tag(Tab.cleanup)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if tab == .audio && hasAudio {
                audioTab
            } else {
                cleanupTab
            }
        }
        .padding(14)
        .frame(width: 340 * textScale)
        .background(STheme.windowBg)
    }

    // MARK: Audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcribe the recording again, and replace the text.")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    modelRow(String(localized: "Current model")) { onRegenerate(nil) }
                    ForEach(RegenerationModelFamily.allCases, id: \.self) { family in
                        let inFamily = models.filter { $0.family == family }
                        if !inFamily.isEmpty {
                            familyHeader(family)
                            ForEach(inFamily.indices, id: \.self) { i in
                                modelRow(inFamily[i].option.displayName) { onRegenerate(inFamily[i].option) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300 * textScale)
        }
    }

    private func familyHeader(_ family: RegenerationModelFamily) -> some View {
        Group {
            switch family {
            case .parakeet: Text(verbatim: "Parakeet")
            case .whisper: Text(verbatim: "Whisper")
            case .senseVoice: Text(verbatim: "SenseVoice")
            case .appleSpeech: Text(verbatim: "Apple Speech")
            case .remote: Text("Server")
            }
        }
        .scaledFont(size: 11, weight: .bold)
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundColor(STheme.hint)
        .padding(.top, 10).padding(.horizontal, 8)
    }

    private func modelRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onClose()
        } label: {
            Text(verbatim: title)
                .scaledFont(size: 13)
                .foregroundColor(STheme.textBright)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: AI cleanup

    @ViewBuilder private var cleanupTab: some View {
        if !cleanupAvailable {
            hint("Turn on AI cleanup in Settings to run it again on this dictation.")
        } else if backends.isEmpty {
            hint("No AI engine is set up on this Mac yet. Choose one in Settings.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                hint("Run the cleanup again on the text the engine wrote. The audio is not touched.")
                field("AI engine") { backendMenu }
                if backend?.editsModel == true {
                    field("Model") { STextField("Model id", text: $model, monospaced: true, width: nil) }
                }
                field("Writing style") { styleMenu }
                field("Extra instruction for this pass") {
                    STextField("Optional, for this run only", text: $extraInstruction, width: nil)
                }
                Button("Run") {
                    onCleanup(HistoryRestyle.Request(style: style, backend: backendTag,
                                                     model: backend?.editsModel == true ? model : nil,
                                                     extraInstruction: extraInstruction))
                    onClose()
                }
                .buttonStyle(.sPrimary)
                .disabled(backend?.editsModel == true && model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var backendMenu: some View {
        SMenu(Text(verbatim: backend?.title ?? "")) {
            ForEach(backends) { option in
                Button(option.title) {
                    backendTag = option.tag
                    model = option.configuredModel ?? ""
                }
            }
        }
    }

    private var styleMenu: some View {
        SMenu(Text(verbatim: WritingStyleText.name(style))) {
            ForEach(WritingStyle.builtIns + AppPreferences.shared.customWritingStyles) { option in
                Button(WritingStyleText.name(option)) { style = option }
            }
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .scaledFont(size: 12)
            .foregroundColor(STheme.hint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 11, weight: .bold)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundColor(STheme.hint)
            content()
        }
    }
}

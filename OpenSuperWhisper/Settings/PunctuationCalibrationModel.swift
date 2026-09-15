import Foundation
import SwiftUI

/// Drives the read-aloud calibration: record a sentence, transcribe it, compare, move on.
@MainActor
final class PunctuationCalibrationModel: ObservableObject {

    enum Stage { case reading, working, review }

    /// One rule the comparison suggests, with the sentence that produced it so the user can see
    /// what they are agreeing to rather than a bare pair of strings.
    struct Proposal: Identifiable {
        let id = UUID()
        var entry: CustomDictionaryEntry
        var example: String
        var keep: Bool = true
    }

    @Published private(set) var stage: Stage = .reading
    @Published private(set) var index = 0
    @Published private(set) var isRecording = false
    @Published private(set) var sentences: [PunctuationCalibration.Sentence] = []
    @Published var proposals: [Proposal] = []

    private var learned: [PunctuationCalibration.DerivedRule] = []

    var currentSentence: PunctuationCalibration.Sentence? {
        sentences.indices.contains(index) ? sentences[index] : nil
    }

    var acceptedEntries: [CustomDictionaryEntry] {
        proposals.filter(\.keep).map(\.entry)
    }

    func start() {
        guard sentences.isEmpty else { return }
        // Follow the dictation language, falling back to the system's. Someone dictating French
        // should not be handed English sentences to read.
        let language = AppPreferences.shared.whisperLanguage == "auto"
            ? (Locale.preferredLanguages.first ?? "en")
            : AppPreferences.shared.whisperLanguage
        sentences = PunctuationCalibration.sentences(for: language)
    }

    func toggleRecording() {
        isRecording ? stop() : begin()
    }

    private func begin() {
        AudioRecorder.shared.startRecording()
        isRecording = true
    }

    private func stop() {
        isRecording = false
        guard let url = AudioRecorder.shared.stopRecording().url, let sentence = currentSentence else {
            advance()
            return
        }

        stage = .working
        Task {
            // A failed clip is not worth an error screen here: the sentence simply teaches
            // nothing and we move to the next one.
            let heard = (try? await TranscriptionService.shared.transcribeAudio(
                url: url, settings: Settings())) ?? ""
            try? FileManager.default.removeItem(at: url)

            learned += PunctuationCalibration.derive(expected: sentence.text, heard: heard)
            advance()
        }
    }

    private func advance() {
        if index + 1 < sentences.count {
            index += 1
            stage = .reading
        } else {
            finishEarly()
        }
    }

    func finishEarly() {
        proposals = PunctuationCalibration.entries(from: learned).map { entry in
            Proposal(entry: entry, example: example(for: entry))
        }
        stage = .review
    }

    /// Shows the rule doing its job, so "attaches to the left" is visible rather than described.
    private func example(for entry: CustomDictionaryEntry) -> String {
        let spoken = entry.original
        let sample: String
        switch entry.spacing {
        case .attachesRight: sample = "he said \(spoken) yes"
        case .attachesLeft: sample = "yes \(spoken) he said"
        case .standalone: sample = "yes \(spoken) no"
        }
        return CustomDictionary.apply(sample, entries: [entry])
    }
}

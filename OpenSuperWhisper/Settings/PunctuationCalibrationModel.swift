import Combine
import Foundation
import SwiftUI
import OpenSuperWhisperCore

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
    /// Why a start this sheet asked for was refused, under the sentence until the next attempt.
    /// Only a refusal that lands while this sheet is the one recording gets here, so a dictation
    /// started elsewhere cannot put its reason on this sheet.
    @Published private(set) var refusalMessage: String?
    @Published private(set) var sentences: [PunctuationCalibration.Sentence] = []
    @Published var proposals: [Proposal] = []

    private var learned: [PunctuationCalibration.DerivedRule] = []
    private var cancellables = Set<AnyCancellable>()

    /// `startFailures` is the recorder's refusal feed, injectable so a test can drive one without
    /// a microphone. It is expected to replay its current value on subscribe, like `@Published`:
    /// that first emission is a previous take's and is skipped.
    init(startFailures: AnyPublisher<String?, Never> =
            AudioRecorder.shared.$startFailureMessage.eraseToAnyPublisher()) {
        // A start this sheet asked for can be refused before the recorder opens (no microphone,
        // a switch that fails). `begin` shows the button as recording by the time the refusal
        // lands, so put it back and keep the reason under the sentence: the same sentence stays
        // up to try again, and a later stop cannot advance as if a take happened. `dropFirst`
        // skips a failure from an earlier take, and `isRecording` keeps another caller's failure
        // off this sheet. (#360 review)
        startFailures
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self = self, let message, self.isRecording else { return }
                self.isRecording = false
                self.refusalMessage = message
            }
            .store(in: &cancellables)
    }

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
        // The reason belonged to the attempt just finished; this one starts clean.
        refusalMessage = nil
        // `startRecording` reports a refusal on a later main-actor turn (`reportStartFailure`
        // hops through a Task), so `isRecording` is already true when the sink above resets it.
        // The flag must be set before this method returns; the order of these two lines is not
        // what carries that.
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

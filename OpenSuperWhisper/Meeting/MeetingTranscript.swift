import Foundation

/// Where speech sits in a meeting track, and how the two tracks become one transcript (#159).
/// Pure, so the rules are pinned by tests rather than by recording a call.
enum MeetingTranscript {
    enum Speaker: Equatable {
        case me, others
    }

    struct Utterance: Equatable {
        let speaker: Speaker
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    // MARK: - Finding speech

    /// The tracks are written at this rate, mono, which is also what the engines take.
    static let sampleRate = 16_000.0
    /// The energy of one window decides whether it holds speech.
    static let frameLength = 0.03
    /// Below this, a window is silence. A meeting track is either a microphone close to someone
    /// talking or the call's own audio, both well above it when someone speaks.
    static let speechLevel: Float = 0.006
    /// A pause shorter than this stays inside the passage: people breathe between clauses.
    static let joinGap = 0.8
    /// A passage shorter than this is a cough or a click.
    static let shortestPassage = 0.4
    /// A passage longer than this is cut, so no single transcription runs too long and a
    /// timestamp is never far from the words it marks.
    static let longestPassage = 25.0

    /// The root mean square of each consecutive window of `samples`.
    static func frameLevels(_ samples: [Float]) -> [Float] {
        let size = Int(frameLength * sampleRate)
        return stride(from: 0, to: samples.count, by: size).map { start in
            let window = samples[start..<min(start + size, samples.count)]
            let power = window.reduce(Float(0)) { $0 + $1 * $1 } / Float(window.count)
            return power.squareRoot()
        }
    }

    /// The passages of speech, in seconds from the start of the track, from its window levels.
    static func passages(levels: [Float]) -> [ClosedRange<TimeInterval>] {
        var passages: [ClosedRange<TimeInterval>] = []
        var start: Int?
        var lastSpeech = 0
        let joinFrames = Int(joinGap / frameLength)

        func close() {
            guard let first = start else { return }
            let from = Double(first) * frameLength
            let to = Double(lastSpeech + 1) * frameLength
            if to - from >= shortestPassage { passages += split(from...to) }
            start = nil
        }

        for (index, level) in levels.enumerated() where level >= speechLevel {
            if start != nil, index - lastSpeech > joinFrames { close() }
            if start == nil { start = index }
            lastSpeech = index
        }
        close()
        return passages
    }

    private static func split(_ range: ClosedRange<TimeInterval>) -> [ClosedRange<TimeInterval>] {
        var pieces: [ClosedRange<TimeInterval>] = []
        var from = range.lowerBound
        while range.upperBound - from > longestPassage {
            pieces.append(from...(from + longestPassage))
            from += longestPassage
        }
        pieces.append(from...range.upperBound)
        return pieces
    }

    // MARK: - Merging the tracks

    /// Without headphones the microphone hears the call too. When echo cancellation lets some
    /// of it through, the same words come back on the "Me" track at the same moment as on the
    /// "Others" one. Such an utterance is dropped when at least this share of its words were
    /// said by the others in an overlapping passage.
    static let echoWordShare = 0.6

    /// Both tracks in time order, the microphone's echoes of the call removed, and the
    /// consecutive passages of one speaker joined.
    static func merged(_ utterances: [Utterance]) -> [Utterance] {
        let others = utterances.filter { $0.speaker == .others }
        let kept = utterances.filter { $0.speaker == .others || !isEcho($0, of: others) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var joined: [Utterance] = []
        for utterance in kept {
            if let last = joined.last, last.speaker == utterance.speaker {
                joined[joined.count - 1] = Utterance(speaker: last.speaker, start: last.start,
                                                     end: utterance.end, text: last.text + " " + utterance.text)
            } else {
                joined.append(utterance)
            }
        }
        return joined
    }

    private static func isEcho(_ mine: Utterance, of others: [Utterance]) -> Bool {
        let myWords = words(mine.text)
        guard !myWords.isEmpty else { return false }
        let heard = others.filter { $0.start < mine.end + 1 && $0.end > mine.start - 1 }
            .reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
        let shared = myWords.filter { heard.contains($0) }.count
        return Double(shared) / Double(myWords.count) >= echoWordShare
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: - Markdown

    /// The transcript as a Markdown document: a title with the date, the length, then one
    /// paragraph per turn with its time and speaker.
    static func markdown(_ utterances: [Utterance], startedAt: Date, duration: TimeInterval,
                         me: String, others: String) -> String {
        let title = startedAt.formatted(date: .long, time: .shortened)
        var lines = ["# \(String(localized: "Meeting")), \(title)", "",
                     String(localized: "Duration: \(clock(duration))"), ""]
        for utterance in utterances {
            let name = utterance.speaker == .me ? me : others
            lines.append("**[\(clock(utterance.start))] \(name):** \(utterance.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

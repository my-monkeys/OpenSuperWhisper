import Foundation
import XCTest
@testable import OpenSuperWhisperCore

/// Local benchmark for Parakeet with boost terms (#235): latency, word error rate and false
/// replacements across four arms — no terms, snippet terms, an inert term with the boost on, and
/// the terms reduced from a focused field, dispatched the way a dictation dispatches them. Needs
/// downloaded models and labelled clips, so it only runs when `OSW_PARAKEET_BENCH` points at a
/// folder of WAVs with a `_refs.json` (`[{ "file", "ref" }]`); the report goes to
/// `OSW_PARAKEET_BENCH_OUT`.
final class ParakeetBoostBenchmark: CoreTestCase {

    /// Names that are in the clips, which the model tends to spell its own way.
    static let spokenTerms = ["Sintra", "Marianas", "Dunlap", "Bennet", "Nyiragongo"]
    /// Short words nobody says in the clips: any of them in an output is a false replacement.
    static let baitTerms = ["Rsets", "Kai", "Ola", "Zed", "Tam", "Nix", "Obo", "Vex"]

    /// A realistic mail field with names the clips never say: the maintainer's measured downside
    /// case (#307), where a term from the focused field can replace a correctly heard word.
    /// When he shares the two fields that actually over-boosted, replacing this constant with
    /// them is the upgrade path; the arm plumbing does not change.
    static let fieldText = """
        Please send the Priya draft to Argo before Thursday, and copy Kestrel on the review. \
        The Cherith notes are in the shared folder, so Argo can pick them up after lunch.
        """

    /// An ordinary-word dictionary that does not know the field's names, so the reduction is the
    /// same on every machine. The app injects the OS spelling dictionary, which knows the ordinary
    /// words and not these names.
    static let fieldSpelling = DictionaryCandidates.Spelling(
        knows: { word in !["priya", "argo", "kestrel", "cherith"].contains(word.lowercased()) },
        correctsTypo: { _ in false })

    /// A term no clip can contain. With the boost on, any output difference from the `none` arm is
    /// the decode path a non-empty term list selects, not a term replacement (memo section 3).
    static let inertTerm = "Xqzv"

    private struct Clip: Decodable { let file: String; let ref: String }

    /// One measured arm: the terms it boosts toward and whether they arrive as the field's terms
    /// (the `TermContextEngine` dispatch) or as the clip's snippet triggers.
    private struct Arm {
        let name: String
        let terms: [String]
        let viaField: Bool
    }

    func testBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["OSW_PARAKEET_BENCH"] else {
            throw XCTSkip("Set OSW_PARAKEET_BENCH to a folder of labelled clips to run it.")
        }
        let directory = URL(fileURLWithPath: folder)
        let clips = try JSONDecoder().decode([Clip].self,
                                             from: Data(contentsOf: directory.appendingPathComponent("_refs.json")))
        let engine = FluidAudioEngine(versionOverride: "v3")
        try await engine.initialize()

        // The field arm feeds the reducer's output through the engine's field dispatch, the way a
        // dictation with a focused field does. The inert arm keeps the boost on with a term no
        // clip can contain, so the decode path it selects can be separated from a replacement.
        let fieldTerms = FieldContextTerms.terms(from: Self.fieldText,
                                                 spelling: Self.fieldSpelling,
                                                 capitalMarksNames: true)
        // Every arm is scored against the same list, so the counts compare across arms: the clips
        // never say the fixed baits, the field's names or the inert term.
        let baits = Self.baitTerms + fieldTerms + [Self.inertTerm]
        let arms = [
            Arm(name: "none", terms: [], viaField: false),
            Arm(name: "terms", terms: Self.spokenTerms + Self.baitTerms, viaField: false),
            Arm(name: "inert", terms: [Self.inertTerm], viaField: true),
            Arm(name: "field", terms: fieldTerms, viaField: true),
        ]

        var report: [String: Any] = [:]
        // `none` runs first; every arm is then compared to its transcript clip by clip, so the
        // inert arm can show a decode-path change that a bait count alone would miss.
        var baselineTexts: [String: String] = [:]
        for arm in arms {
            var settings = Fixtures.pinnedSettings()
            if !arm.viaField { settings.snippetTriggers = arm.terms }
            var rows: [[String: Any]] = []
            var errors = 0, words = 0, baitsFound = 0, transcriptDiffs = 0, totalMs = 0.0
            // The first dictation pays any one-off load, so it is timed apart.
            for clip in clips {
                let start = Date()
                let url = directory.appendingPathComponent(clip.file)
                let text: String
                if arm.viaField {
                    text = try await engine.transcribeAudio(url: url, settings: settings,
                                                            terms: arm.terms)
                } else {
                    text = try await engine.transcribeAudio(url: url, settings: settings)
                }
                let ms = Date().timeIntervalSince(start) * 1000
                let hyp = Self.words(text), ref = Self.words(clip.ref)
                let distance = Self.editDistance(ref, hyp)
                let found = baits.filter { bait in hyp.contains(bait.lowercased()) }
                let baseline = baselineTexts[clip.file]
                let differs = baseline.map { $0 != text } ?? false
                if baseline == nil { baselineTexts[clip.file] = text }
                errors += distance; words += ref.count; baitsFound += found.count
                totalMs += ms; if differs { transcriptDiffs += 1 }
                rows.append(["file": clip.file, "ms": Int(ms), "text": text, "bait": found,
                             "differsFromNone": differs])
            }
            report[arm.name] = ["wer": Double(errors) / Double(max(words, 1)), "baits": baitsFound,
                                "transcriptDiffs": transcriptDiffs,
                                "terms": arm.terms, "viaField": arm.viaField,
                                "totalMs": Int(totalMs), "firstMs": rows.first?["ms"] ?? 0,
                                "clips": rows]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out = environment["OSW_PARAKEET_BENCH_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}

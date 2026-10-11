import SwiftUI
import OpenSuperWhisperCore

/// An example sentence and what the entry does to it, computed by `CustomDictionary.apply`, the
/// same function the dictation pipeline runs. The rule doing its job beats a description of it.
struct DictionaryTestBox: View {
    @Binding var sample: String
    let entry: CustomDictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test")
                .scaledFont(size: 11, weight: .bold)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(STheme.hint)
            TextField("Type a sentence to try", text: $sample)
                .textFieldStyle(.plain)
                .scaledFont(size: 14)
                .foregroundColor(STheme.textBright)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
            Text(DictionaryPreview.matched(in: sample, by: entry))
                .scaledFont(size: 14)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            Text(DictionaryPreview.result(of: sample, with: entry))
                .scaledFont(size: 14)
                .foregroundColor(STheme.textBright)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.fill))
    }
}

/// Builds the two lines of the test box.
enum DictionaryPreview {
    private static let markStart: Character = "\u{E000}"
    private static let markEnd: Character = "\u{E001}"

    /// The sentence with every variant the entry matches struck through.
    ///
    /// Mirrors the matching of `CustomDictionary.apply` (case-insensitive, word boundaries only
    /// where the variant starts or ends with a word character) because that function only
    /// returns the rewritten text. It only decides what gets struck; the result line below
    /// comes from the real function.
    static func matched(in sample: String, by entry: CustomDictionaryEntry) -> AttributedString {
        let ns = sample as NSString
        var taken: [NSRange] = []
        for trigger in entry.triggers.sorted(by: { $0.count > $1.count }) {
            guard let regex = try? NSRegularExpression(pattern: pattern(for: trigger, regex: entry.isRegex),
                                                       options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: sample, range: NSRange(location: 0, length: ns.length))
            where match.range.length > 0 && !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                taken.append(match.range)
            }
        }
        var out = AttributedString()
        var cursor = 0
        for range in taken.sorted(by: { $0.location < $1.location }) {
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var struck = AttributedString(ns.substring(with: range))
            struck.strikethroughStyle = .single
            out += struck
            cursor = range.location + range.length
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }

    /// What `CustomDictionary.apply` returns, with the inserted text highlighted.
    ///
    /// The highlight comes from running the entry a second time with its replacement wrapped in
    /// two private-use characters. When that changes the outcome (a replacement starting or
    /// ending with a line break eats spaces the wrapped one does not), the line is shown plain
    /// rather than highlighted wrongly.
    static func result(of sample: String, with entry: CustomDictionaryEntry) -> AttributedString {
        let real = CustomDictionary.apply(sample, entries: [entry])
        var marked = entry
        marked.replacement = "\(markStart)\(entry.trimmedReplacement)\(markEnd)"
        let markedResult = CustomDictionary.apply(sample, entries: [marked])
        let stripped = markedResult.filter { $0 != markStart && $0 != markEnd }
        guard stripped == real else { return AttributedString(visible(real)) }

        var out = AttributedString()
        var segment = ""
        for character in markedResult {
            if character == markStart || character == markEnd {
                out += piece(segment, highlighted: character == markEnd)
                segment = ""
            } else {
                segment.append(character)
            }
        }
        out += piece(segment, highlighted: false)
        return out
    }

    private static func piece(_ text: String, highlighted: Bool) -> AttributedString {
        var piece = AttributedString(visible(text))
        if highlighted {
            piece.foregroundColor = STheme.accent
            piece.backgroundColor = STheme.accentSoft
            piece.inlinePresentationIntent = .stronglyEmphasized
        }
        return piece
    }

    /// Line breaks and tabs made visible, since the box is a single line of text.
    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
    }

    private static func pattern(for trigger: String, regex: Bool) -> String {
        guard !regex else { return trigger }
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        let leading = isWordCharacter(trigger.first) ? "\\b" : ""
        let trailing = isWordCharacter(trigger.last) ? "\\b" : ""
        return leading + escaped + trailing
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}

import SwiftUI

/// The last step: a field to dictate into with the real shortcut. The shortcut types into whichever
/// field has the caret, so a focused editor in this window is a test target like any other app.
struct OnboardingFirstTryStep: View {
    /// One cap per key of the shortcut that starts a dictation.
    let triggerCaps: [String]
    let microphoneGranted: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KeysSentence(caps: triggerCaps)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .scaledFont(size: 16)
                    .foregroundColor(STheme.textBright)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 12)
                if text.isEmpty {
                    Text("Your words will appear here.")
                        .scaledFont(size: 16)
                        .foregroundColor(STheme.faint)
                        .padding(.horizontal, 17).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? STheme.accent : STheme.border, lineWidth: focused ? 2 : 1))

            Text("For example: \u{201C}I'll send you the mockups tomorrow morning.\u{201D}")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingCallout {
                Text("The words land wherever the cursor is: here, or in any other app.")
                if !microphoneGranted {
                    Text("The microphone isn't allowed yet, so nothing will be heard. Go back a step to allow it.")
                        .foregroundColor(STheme.warn)
                }
            }
        }
        .onAppear {
            // Once the window has laid the editor out, or the focus request is dropped.
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// "Hold ⌥ < and say a sentence" with the keys drawn as caps, wrapping with the words. The
/// sentence is one localized string, so each language keeps its own word order; the caps take
/// the place of its placeholder, wherever the translation puts it.
private struct KeysSentence: View {
    let caps: [String]
    @Environment(\.locale) private var locale

    /// Stands in for the keys inside the localized sentence. Private use, so no translation
    /// can contain it.
    private static let marker = "\u{E000}"

    private enum Piece: Hashable {
        case word(String)
        case keys
    }

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 4, centersLines: true) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .word(let word):
                    Text(verbatim: word)
                        .scaledFont(size: 18, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                case .keys:
                    HStack(spacing: 4) {
                        ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in SKeyCap(cap) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: sentence.replacingOccurrences(
            of: Self.marker, with: caps.joined(separator: " "))))
    }

    /// Read with the view's locale rather than the process's, like any `Text`.
    private var sentence: String {
        var resource = LocalizedStringResource("Hold \(Self.marker) and say a sentence")
        resource.locale = locale
        return String(localized: resource)
    }

    private var pieces: [Piece] {
        sentence.split(separator: " ").flatMap { word -> [Piece] in
            let parts = word.components(separatedBy: Self.marker)
            guard parts.count > 1 else { return [.word(String(word))] }
            return parts.enumerated().flatMap { index, part -> [Piece] in
                let text: [Piece] = part.isEmpty ? [] : [.word(part)]
                return index == 0 ? text : [.keys] + text
            }
        }
    }
}

import SwiftUI

/// Step 4: a field to dictate into with the real shortcut. The shortcut types into whichever
/// field has the caret, so a focused editor in this window is a test target like any other app.
struct OnboardingFirstTryStep: View {
    let triggerKeys: String
    let microphoneGranted: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hold \(triggerKeys) and say a sentence")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundColor(STheme.textBright)
                .fixedSize(horizontal: false, vertical: true)

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

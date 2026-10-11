import SwiftUI
import OpenSuperWhisperCore

struct AssistantsRubric: View {
    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.assistants, intro: "Dictate your answers to Claude Code and Codex, and hear when they are waiting.") {
            Text(verbatim: "…")
        }
    }
}

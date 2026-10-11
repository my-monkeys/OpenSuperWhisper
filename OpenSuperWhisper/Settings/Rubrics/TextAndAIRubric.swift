import SwiftUI
import OpenSuperWhisperCore

struct TextAndAIRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.textAndAI, intro: "What happens to the text between your voice and the app: cleanup, formatting, insertion.") {
            Text(verbatim: "…")
        }
    }
}

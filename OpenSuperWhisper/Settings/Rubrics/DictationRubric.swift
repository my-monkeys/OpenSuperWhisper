import SwiftUI
import OpenSuperWhisperCore

struct DictationRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.dictation, intro: "How you start a dictation, and what happens during it.") {
            Text(verbatim: "…")
        }
    }
}

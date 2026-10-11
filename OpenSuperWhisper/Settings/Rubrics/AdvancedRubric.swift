import SwiftUI
import OpenSuperWhisperCore

struct AdvancedRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.advanced, intro: "Decoding, the post-record hook and logs. Nothing to set to get started.") {
            Text(verbatim: "…")
        }
    }
}

import SwiftUI
import OpenSuperWhisperCore

struct PrivacyRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.privacy, intro: "What is kept on this Mac, and for how long.") {
            Text(verbatim: "…")
        }
    }
}

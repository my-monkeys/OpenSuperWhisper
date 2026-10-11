import SwiftUI
import OpenSuperWhisperCore

struct GeneralRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.general, intro: "How the app starts and which language it speaks.") {
            Text(verbatim: "…")
        }
    }
}

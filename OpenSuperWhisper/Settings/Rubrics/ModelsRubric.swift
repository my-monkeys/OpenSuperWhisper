import SwiftUI
import OpenSuperWhisperCore

struct ModelsRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.models, intro: "The model that turns your voice into text. Everything runs on this Mac unless you pick a server.") {
            Text(verbatim: "…")
        }
    }
}

import SwiftUI
import OpenSuperWhisperCore

struct AppearanceRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = []

    var body: some View {
        RubricPage(.appearance, intro: "How the app and the recording bubble look.") {
            Text(verbatim: "…")
        }
    }
}

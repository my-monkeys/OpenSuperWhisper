import SwiftUI
import OpenSuperWhisperCore

struct DictionaryPage: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Text(verbatim: "…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

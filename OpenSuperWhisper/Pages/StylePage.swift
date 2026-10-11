import SwiftUI
import OpenSuperWhisperCore

struct StylePage: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Text(verbatim: "…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

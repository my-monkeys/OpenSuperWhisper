import SwiftUI
import OpenSuperWhisperCore

/// How text is formatted: the writing styles. What is set for one app lives on the Per app page.
struct StylePage: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Style", subtitle: "How your text is formatted. Pick a style, then say where it applies.")
                WritingStyleCards(viewModel: viewModel)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

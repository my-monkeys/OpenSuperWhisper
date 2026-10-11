import SwiftUI
import OpenSuperWhisperCore

struct HelpOverlay: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        ModalCard(maxWidth: 760, onClose: { navigation.helpOpen = false }) {
            UpdatesView()
        }
    }
}

import SwiftUI
import OpenSuperWhisperCore

/// Settings → Appearance: how the app and the recording bubble look. The bubble's position, its
/// preview and its contents all live here, so everything visible is set in one place.
struct AppearanceRubric: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var appearance = AppearanceController.shared
    @ObservedObject private var themeController = ThemeController.shared

    static let searchEntries: [SettingsSearchEntry] = [
        entry("Theme", keywords: "dark light mode thème sombre clair système apparence"),
        entry("Liquid Glass", keywords: "glass transparency verre transparent Tahoe"),
        entry("Text size", keywords: "font scale zoom taille du texte police"),
        entry("Position", keywords: "bubble indicator notch cursor bulle indicateur position encoche curseur"),
        entry("Bubble size", keywords: "indicator size taille de la bulle"),
        entry("Order and display", advanced: true,
              keywords: "elements stop cancel button dot label ordre affichage éléments bouton point libellé"),
        entry("Waveform style", advanced: true, keywords: "bars spectrum dots forme d'onde barres spectre points"),
        entry("Waveform height", advanced: true, keywords: "meter hauteur de la forme d'onde"),
        entry("Simulated notch on screens without one", advanced: true,
              keywords: "notch fake notch simulée encoche écran"),
        entry("Notch opening width", advanced: true, keywords: "notch width largeur d'ouverture de la notch encoche"),
    ]

    private static func entry(_ title: String, advanced: Bool = false, keywords: String) -> SettingsSearchEntry {
        SettingsSearchEntry(title: title, rubric: .appearance, advanced: advanced, keywords: keywords)
    }

    var body: some View {
        RubricPage(.appearance, intro: "How the app and the recording bubble look.") {
            SettingsGroup("General") {
                SettingRow("Theme", hint: "System follows macOS.") {
                    SSegmented(selection: $appearance.appearance,
                               options: AppAppearance.allCases.map { ($0, $0.title) })
                }
                SettingRow("Liquid Glass", hint: glassHint) {
                    SSwitch(isOn: liquidGlass)
                        .disabled(!Self.glassAvailable)
                }
                SettingRow("Text size", hint: "Added on top of the macOS text size.") {
                    SSlider(value: $viewModel.textScale.rubricSnapped(to: 0.05),
                            range: TextScale.minimum...TextScale.maximum,
                            valueLabel: "\(Int((viewModel.textScale * 100).rounded())) %")
                }
            }
            AppearanceBubbleGroup(viewModel: viewModel)
        }
    }

    private static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    private var glassHint: LocalizedStringKey {
        Self.glassAvailable
            ? "Transparent glass on the window and the bubble."
            : "Transparent glass on the window and the bubble. macOS 26 and later."
    }

    /// On means "follow the system", which resolves to glass on macOS 26 and later, so a Mac
    /// upgraded later gets it without a second visit here.
    private var liquidGlass: Binding<Bool> {
        Binding(get: { themeController.theme.resolved == .liquidGlass },
                set: { themeController.theme = $0 ? .system : .legacy })
    }
}

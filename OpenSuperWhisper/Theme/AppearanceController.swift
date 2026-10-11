import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// Light or dark for the app's windows, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// What `NSApp.appearance` takes: nil follows macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the `appAppearance` preference and applies it to the whole app, so the main window, the
/// agent panel and onboarding all follow it through `STheme`'s adaptive colours.
@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    @Published var appearance: AppAppearance {
        didSet {
            AppPreferences.shared.appAppearance = appearance.rawValue
            apply()
        }
    }

    private init() {
        appearance = AppAppearance(rawValue: AppPreferences.shared.appAppearance) ?? .system
    }

    func apply() {
        NSApp?.appearance = appearance.nsAppearance
    }
}

/// Which settings rubrics show their advanced options. Published so every open rubric redraws
/// when its switch moves, and persisted in `settingsAdvancedRubrics`.
@MainActor
final class AdvancedRubrics: ObservableObject {
    static let shared = AdvancedRubrics()

    @Published private(set) var enabled: Set<String>

    private init() {
        enabled = Set(AppPreferences.shared.settingsAdvancedRubrics)
    }

    func isOn(_ rubric: String) -> Bool { enabled.contains(rubric) }

    func set(_ rubric: String, _ on: Bool) {
        if on { enabled.insert(rubric) } else { enabled.remove(rubric) }
        AppPreferences.shared.settingsAdvancedRubrics = enabled.sorted()
    }
}

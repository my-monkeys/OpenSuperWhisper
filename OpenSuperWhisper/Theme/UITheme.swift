import SwiftUI

// The app's UI theme, so the legacy (pre-Tahoe) look and the new Liquid Glass look can both ship
// during the transition. The design keeps the choice out of the call sites: the `#available` OS
// check and the legacy-vs-glass branch each live in exactly one place (`resolved` here, and the
// `BubbleSurface` seam), so adopting the theme never sprays conditionals through the views.

/// What the user picked. `.system` follows the OS; the two explicit cases pin the look.
enum UITheme: String, CaseIterable, Identifiable {
    case system
    case legacy
    case liquidGlass

    var id: String { rawValue }

    /// A key, not a String: `Text(String)` shows its argument verbatim, so the picker would never
    /// translate the names.
    var displayName: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .legacy: return "Legacy"
        case .liquidGlass: return "Liquid Glass"
        }
    }

    /// Collapse to what actually renders: never `.system`, and never `.liquidGlass` on macOS < 26,
    /// where the glass APIs do not exist. This is the ONE place the OS availability check lives, so
    /// no view needs `#available` to pick a theme.
    var resolved: UITheme {
        switch self {
        case .legacy:
            return .legacy
        case .system, .liquidGlass:
            if #available(macOS 26.0, *) { return .liquidGlass } else { return .legacy }
        }
    }
}

// MARK: - Environment

private struct UIThemeKey: EnvironmentKey {
    /// A resolved value (never `.system`); each hosting root injects the real one from
    /// `ThemeController`. The default only matters for previews and stray hosts.
    static let defaultValue: UITheme = .legacy
}

extension EnvironmentValues {
    /// The RESOLVED theme for this view tree. Read it in themed seams; inject it once at each
    /// `NSHostingView`/`NSHostingController` root via `ThemeController.shared.resolved`.
    var uiTheme: UITheme {
        get { self[UIThemeKey.self] }
        set { self[UIThemeKey.self] = newValue }
    }
}

// MARK: - Controller

/// Reactive wrapper around the persisted theme preference. `AppPreferences` is not observable, so
/// this publishes changes for the Settings picker and hands each hosting root the resolved value.
final class ThemeController: ObservableObject {
    static let shared = ThemeController()

    @Published var theme: UITheme {
        didSet { AppPreferences.shared.uiTheme = theme.rawValue }
    }

    /// Size factor of the Liquid Glass bubble; the indicator reads it once per presentation.
    @Published var glassBubbleSize: Double {
        didSet { AppPreferences.shared.glassBubbleSize = glassBubbleSize }
    }

    static let glassBubbleSizeRange: ClosedRange<Double> = 0.6...1.2

    private init() {
        theme = UITheme(rawValue: AppPreferences.shared.uiTheme) ?? .system
        glassBubbleSize = AppPreferences.shared.glassBubbleSize
    }

    /// What renders now: resolved (never `.system`, OS-degraded). The indicator reads this once per
    /// presentation, matching how it already reads `textScale` once (a mid-recording change should
    /// not reskin the bubble under the user).
    var resolved: UITheme { theme.resolved }
}

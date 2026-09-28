import SwiftUI
import LiquidGlass

// The recording bubble's surface, chosen by theme. The legacy-vs-glass `switch` lives HERE only —
// `IndicatorWindow` just puts `BubbleSurface(shape:)` behind its content and stays theme-agnostic.
// The glass surface comes from the LiquidGlass package (so the app and the package's previews share
// one implementation); the legacy surface stays in the app, since it is the old look, not a Liquid
// Glass component.

struct BubbleSurface: View {
    @Environment(\.uiTheme) private var theme
    let shape: AnyShape

    var body: some View {
        switch theme {
        case .liquidGlass:
            // The clear (most transparent) macOS 26 glass, no custom rim so the system draws its own
            // edge and the surface reads as truly clear. Passthrough below 26, but the theme never
            // resolves to `.liquidGlass` there, so that path is never taken.
            Color.clear.liquidGlassSurface(in: shape, glass: .clear, rim: false)
        case .legacy, .system:
            // `.system` is already resolved away before it reaches a view; kept in the branch so the
            // switch is exhaustive and legacy is the safe fallback.
            LegacyBubbleSurface(shape: shape)
        }
    }
}

/// The pre-Tahoe bubble surface: the thin material with a dark/light tint and a soft drop shadow,
/// exactly as the bubble shipped before Liquid Glass.
struct LegacyBubbleSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    let shape: AnyShape

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.24)
    }

    var body: some View {
        shape
            .fill(backgroundColor)
            .background {
                shape.fill(Material.thinMaterial)
            }
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
    }
}

import SwiftUI

/// How much larger or smaller the app's text is than its designed size.
///
/// Every size in the app used to be a fixed point value, which meant macOS's own text-size
/// setting did nothing and there was no way to read the settings window if 10pt hints are too
/// small for you (#80). Sizes now pass through here, and get multiplied by two things: what the
/// system asks for, and what the user asked for on top.
///
/// The system comes first because it is already configured and applies everywhere else; the
/// app-level control exists because "follow the system" alone leaves no room for someone who
/// wants this one app bigger than the rest.
enum TextScale {
    /// Bounds chosen so the layout still holds: below 0.85 the key caps stop fitting their
    /// glyphs, and above 1.6 the recording bubble grows past a comfortable overlay size.
    static let minimum: Double = 0.85
    static let maximum: Double = 1.6
    static let `default`: Double = 1.0

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// The system's contribution. `dynamicTypeSize` reflects System Settings → Accessibility →
    /// Display → Text size on macOS 14+, and sits at `.large` when untouched.
    static func systemMultiplier(_ size: DynamicTypeSize) -> Double {
        switch size {
        case .xSmall: return 0.8
        case .small: return 0.9
        case .medium: return 0.95
        case .large: return 1.0
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        case .accessibility1: return 1.5
        case .accessibility2: return 1.7
        case .accessibility3: return 1.9
        case .accessibility4: return 2.1
        case .accessibility5: return 2.3
        @unknown default: return 1.0
        }
    }

    /// Point size to actually render, given both contributions.
    static func resolve(_ size: CGFloat, appScale: Double, system: DynamicTypeSize) -> CGFloat {
        size * CGFloat(clamped(appScale) * systemMultiplier(system))
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = TextScale.default
}

extension EnvironmentValues {
    /// Set once near the root of each window; every `scaledFont` below reads it.
    var appTextScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.appTextScale) private var appScale
    @Environment(\.dynamicTypeSize) private var systemSize

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: TextScale.resolve(size, appScale: appScale, system: systemSize),
                             weight: weight, design: design))
    }
}

extension View {
    /// Replaces `.font(.system(size:))`. The number stays the designed size; what reaches the
    /// screen is that size scaled by the system setting and the user's own adjustment.
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

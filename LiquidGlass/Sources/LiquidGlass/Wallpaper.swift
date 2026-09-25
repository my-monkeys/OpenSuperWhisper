import SwiftUI

// A stand-in macOS desktop for looking at the glass: glass samples and refracts whatever is behind
// it, so a flat fill says nothing about how the bubble really reads. Used by the Canvas previews
// and by the app's screenshot/GIF probe, so every picture of the bubble sits on the same desktop.

/// Which desktop to show behind the bubble.
public enum WallpaperStyle: String, CaseIterable, Sendable {
    /// A dark Tahoe-like mesh: deep indigo and violet with a warm glow low on the screen.
    case night
    /// The light counterpart: pastel lavender, peach and sky.
    case day
    /// The night mesh with an app window across it, so the glass has hard edges and text to bend.
    case busy

    public var displayName: String {
        switch self {
        case .night: return "Night"
        case .day: return "Day"
        case .busy: return "Busy"
        }
    }

    /// The colour scheme a Mac would be in with this desktop.
    public var scheme: ColorScheme { self == .day ? .light : .dark }
}

@available(macOS 15.0, *)
public struct DesktopWallpaper: View {
    var style: WallpaperStyle
    /// Where the bubble sits, as a fraction of the wallpaper. The busy style's window is placed
    /// relative to it so its edge and text run under the bubble wherever that is (centre in the
    /// previews, a strip near the top of the screen in the GIF probe).
    var focus: UnitPoint

    public init(_ style: WallpaperStyle = .night, focus: UnitPoint = .center) {
        self.style = style
        self.focus = focus
    }

    public var body: some View {
        ZStack {
            mesh
            // A soft diagonal sheen, the way the Tahoe wallpapers catch light.
            Ellipse()
                .fill(.white.opacity(style == .day ? 0.35 : 0.10))
                .frame(width: 520, height: 140)
                .rotationEffect(.degrees(-18))
                .blur(radius: 60)
                .offset(x: -80, y: -60)
            if style == .busy {
                GeometryReader { geo in
                    // Top-left corner a little up and left of the bubble's centre, so the window's
                    // top edge and first lines of text pass behind it.
                    window.position(x: geo.size.width * focus.x + 150,
                                    y: geo.size.height * focus.y + 110)
                }
            }
        }
        .clipped()
    }

    private var mesh: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.5], [0.45, 0.55], [1, 0.45],
                [0, 1], [0.6, 1], [1, 1],
            ],
            colors: style == .day ? Self.dayColors : Self.nightColors)
    }

    private static let nightColors: [Color] = [
        Color(red: 0.05, green: 0.07, blue: 0.18), Color(red: 0.18, green: 0.12, blue: 0.42), Color(red: 0.04, green: 0.20, blue: 0.30),
        Color(red: 0.34, green: 0.16, blue: 0.50), Color(red: 0.58, green: 0.22, blue: 0.46), Color(red: 0.16, green: 0.28, blue: 0.60),
        Color(red: 0.06, green: 0.05, blue: 0.14), Color(red: 0.76, green: 0.40, blue: 0.28), Color(red: 0.10, green: 0.10, blue: 0.28),
    ]

    private static let dayColors: [Color] = [
        Color(red: 0.93, green: 0.90, blue: 0.97), Color(red: 0.80, green: 0.84, blue: 0.98), Color(red: 0.97, green: 0.88, blue: 0.84),
        Color(red: 0.86, green: 0.78, blue: 0.95), Color(red: 0.99, green: 0.84, blue: 0.78), Color(red: 0.76, green: 0.90, blue: 0.95),
        Color(red: 0.95, green: 0.93, blue: 0.90), Color(red: 0.88, green: 0.80, blue: 0.94), Color(red: 0.82, green: 0.88, blue: 0.98),
    ]

    /// A dark app window with a title bar and lines of text, offset so its edge runs under the
    /// middle of the frame.
    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in
                    Circle().fill(c.opacity(0.85)).frame(width: 11, height: 11)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(white: 0.16))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Self.lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .padding(14)
            Spacer(minLength: 0)
        }
        .frame(width: 440, height: 250)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }

    private static let lines = [
        "func transcribe(_ clip: AudioClip) async {",
        "    let text = try await engine.run(clip)",
        "    await pipeline.deliver(text)",
        "}",
        "// Liquid Glass bends whatever is behind it",
        "let bubble = RecordingBubble(phase: .recording)",
    ]
}

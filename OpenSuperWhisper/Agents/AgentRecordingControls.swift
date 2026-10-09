import LiquidGlass
import SwiftUI

/// The left end of the agent panel's composer: a microphone that, once a reply is being
/// dictated, swells into the live meter while delete and stop separate from it on either side.
/// On macOS 26 the three are Liquid Glass shapes in one container, so the system morphs them
/// out of the microphone the way it does the recording bubble; earlier systems get a spring.
struct AgentRecordingControls: View {
    let listening: Bool
    let onDictate: () -> Void
    let onDelete: () -> Void
    let onStop: () -> Void

    static let size: CGFloat = 34
    static let spacing: CGFloat = 8
    /// Soft enough to read as liquid, damped enough not to wobble when it settles.
    static let morph = Animation.spring(response: 0.5, dampingFraction: 0.74)

    @Namespace private var glassSpace

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                glassControls
            } else {
                plainControls
            }
        }
        .animation(Self.morph, value: listening)
    }

    // MARK: Liquid Glass

    @available(macOS 26.0, *)
    private var glassControls: some View {
        GlassEffectContainer(spacing: Self.spacing + 4) {
            HStack(spacing: Self.spacing) {
                if listening {
                    icon("trash", tint: .red, action: onDelete, help: "Delete this recording")
                        .glassEffect(.regular.tint(Color.red.opacity(0.18)).interactive(), in: Circle())
                        .glassEffectID("delete", in: glassSpace)
                }
                center
                    .glassEffect(.regular.tint(STheme.accent.opacity(0.22)).interactive(), in: Capsule())
                    .glassEffectID("center", in: glassSpace)
                if listening {
                    icon("stop.fill", tint: STheme.accent, action: onStop,
                         help: "Stop, and put the words in the field")
                        .glassEffect(.regular.interactive(), in: Circle())
                        .glassEffectID("stop", in: glassSpace)
                }
            }
        }
    }

    // MARK: Before macOS 26

    private var plainControls: some View {
        HStack(spacing: Self.spacing) {
            if listening {
                icon("trash", tint: .red, action: onDelete, help: "Delete this recording")
                    .background(Circle().fill(Color.red.opacity(0.14)))
                    .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
            }
            center
                .background(Capsule().fill(STheme.accentSoft))
            if listening {
                icon("stop.fill", tint: STheme.accent, action: onStop,
                     help: "Stop, and put the words in the field")
                    .background(Circle().fill(STheme.accentSoft))
                    .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }
        }
    }

    // MARK: Pieces

    /// One shape for both states, so it grows from the microphone's circle into the meter's pill
    /// rather than one being swapped for the other.
    private var center: some View {
        ZStack {
            if listening {
                AgentLiveMeter()
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(STheme.accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: listening ? Self.meterWidth : Self.size, height: Self.size)
        .contentShape(Capsule())
        .onTapGesture { if !listening { onDictate() } }
        .pointerCursorOnHover()
        .help(listening ? "Recording" : "Dictate the answer")
    }

    static var meterWidth: CGFloat {
        WaveformMeter.width(bands: SpectrumBands.count) + 26
    }

    private func icon(_ symbol: String, tint: Color, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(tint)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .help(help)
    }
}

/// The bubble's own meter, fed by the same spectrum while the microphone is open.
struct AgentLiveMeter: View {
    @ObservedObject private var spectrum = SpectrumAnalyzer.shared

    var body: some View {
        WaveformMeter(height: 18, bands: spectrum.bands)
    }
}

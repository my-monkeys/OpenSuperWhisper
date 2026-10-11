import LiquidGlass
import SwiftUI

/// The left end of the agent panel's composer: a filled terracotta microphone, the panel's main
/// action, that, once a reply is being dictated, swells into the live meter while delete and stop separate from it on either side.
/// On macOS 26 the three are Liquid Glass shapes in one container, so the system morphs them
/// out of the microphone the way it does the recording bubble; earlier systems get a spring.
struct AgentRecordingControls: View {
    let listening: Bool
    let onDictate: () -> Void
    let onDelete: () -> Void
    let onStop: () -> Void

    static let size: CGFloat = 36
    static let spacing: CGFloat = 8
    /// How close two shapes must be for the glass to blend them. Kept under `spacing`, so once
    /// they have separated they stay clean circles; at the container's old 12 pt the settled
    /// shapes were still close enough to be bridged, and each kept a point toward the next.
    static let blendDistance: CGFloat = 4
    /// Soft enough to read as liquid, damped enough not to wobble when it settles.
    static let morph = Animation.spring(response: 0.5, dampingFraction: 0.74)

    @Namespace private var glassSpace

    /// Liquid Glass is composited by the window server, so an off-screen snapshot shows none of
    /// it, the microphone included; the probe draws the plain controls instead.
    @MainActor private static var drawsPlain: Bool {
        #if DEBUG
        AgentPanelController.shared.isSnapshotting
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !Self.drawsPlain {
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
        GlassEffectContainer(spacing: Self.blendDistance) {
            HStack(spacing: Self.spacing) {
                if listening {
                    icon("trash", tint: STheme.danger, action: onDelete, help: "Delete this recording")
                        .glassEffect(.regular.tint(STheme.danger.opacity(0.18)).interactive(), in: Circle())
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
                icon("trash", tint: STheme.danger, action: onDelete, help: "Delete this recording")
                    .background(Circle().fill(STheme.danger.opacity(0.14)))
                    .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
            }
            center
                .background(Capsule().fill(listening ? STheme.accentSoft : Color.clear))
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
    /// A Button rather than a tap gesture: under interactive glass a tap gesture could lose the
    /// click to the glass's own press handling, so it sometimes took a second one.
    private var center: some View {
        Button { if !listening { onDictate() } } label: { centerLabel }
            .buttonStyle(.plain)
            .pointerCursorOnHover()
            .help(listening ? "Recording" : "Dictate the answer")
    }

    private var centerLabel: some View {
        ZStack {
            if listening {
                AgentLiveMeter()
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                // Its own fill, drawn over the glass: a tint alone reads as a pale button.
                Image(systemName: "mic.fill")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(STheme.onAccent)
                    .frame(width: Self.size, height: Self.size)
                    .background(Circle().fill(STheme.accent))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: listening ? Self.meterWidth : Self.size, height: Self.size)
        .contentShape(Capsule())
    }

    static var meterWidth: CGFloat {
        WaveformMeter.width(bands: SpectrumBands.count) + 26
    }

    private func icon(_ symbol: String, tint: Color, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .bold)
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

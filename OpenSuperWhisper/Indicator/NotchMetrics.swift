import AppKit

/// Notch geometry for the menu-bar indicator.
///
/// Two different things wear the name "notch" here, and conflating them is what put the pill
/// behind the hardware. On a Mac with a notch there is a physical cutout the window cannot draw
/// into; on a Mac without one the app draws a pill shaped like a notch, purely as a look. The
/// first has measurements that must be obeyed, the second has preferences that can be tuned.
enum NotchMetrics {

    /// Covers the notch's softened edges. Matching its geometry exactly leaves a hairline of
    /// wallpaper down each side, because the cutout is not a clean rectangle. Same allowance
    /// boring.notch uses.
    static let edgeAllowance: CGFloat = 4

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// The physical cutout, or nil on a screen that has none.
    ///
    /// Returning nil rather than a stand-in is the point: a caller that needs to know whether it
    /// must draw around real hardware cannot be given a plausible number instead. The previous
    /// version always answered, so the drawing code could not tell a measurement from a
    /// preference, and hung a 42pt pill from the top of a screen whose top 38pt are a hole.
    static func physicalNotch(for screen: NSScreen) -> CGSize? {
        guard hasNotch(screen),
              let left = screen.auxiliaryTopLeftArea?.width,
              let right = screen.auxiliaryTopRightArea?.width
        else { return nil }

        let width = screen.frame.width - left - right + edgeAllowance
        return CGSize(width: width, height: screen.safeAreaInsets.top)
    }
}

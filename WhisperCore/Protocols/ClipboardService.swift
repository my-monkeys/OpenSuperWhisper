import Foundation

/// Clipboard seam (plan interface contract — KEPT). Cheap pinned seam for the
/// Cycle 2/3 dictation flow's clipboard interactions; the macOS implementation
/// wraps the existing app-side clipboard utility.
public protocol ClipboardService {
    func copyToClipboard(_ text: String)
}

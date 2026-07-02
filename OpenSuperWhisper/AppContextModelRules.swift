import AppKit
import Foundation

/// The app the user is currently targeting — refreshed at record-start and when
/// the menu-bar picker opens — so binding a model maps to the right app.
/// Runtime-only.
final class RecordingContext {
    static let shared = RecordingContext()
    private(set) var appName: String?
    private(set) var bundleID: String?
    /// URL host for supported browsers (e.g. "docs.google.com") — enables
    /// per-site rules. nil for non-browsers or when the URL is unavailable.
    private(set) var host: String?
    /// Full active-tab URL for supported browsers (for transcript metadata).
    private(set) var fullURL: String?
    /// Focused window title at capture time (for transcript metadata).
    private(set) var windowTitle: String?
    private init() {}

    func update(appName: String?, bundleID: String?, host: String? = nil,
                fullURL: String? = nil, windowTitle: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.host = host
        self.fullURL = fullURL
        self.windowTitle = windowTitle
    }

    /// A label for the most specific bindable scope: the site host if we have
    /// one, otherwise the app name.
    var scopeLabel: String? { host ?? appName }

    /// Capture the current frontmost app (browser site + URL + window title) as
    /// the active context. Opening a status-bar menu doesn't steal focus, so this
    /// is the app the cursor is in. If our own app is frontmost, keep the previous
    /// context.
    func captureFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier
        else { return }
        let url = SourceCapture.browserURL(bundleID: bundle)
        let host = SourceCapture.host(of: url)
        let title = SourceCapture.focusedWindowTitle()
        update(appName: front.localizedName, bundleID: bundle, host: host,
               fullURL: url, windowTitle: title)
    }

    // One-time model override. "Just This Time" makes the *next* recording in an
    // app use the picked model instead of the app's rule, then reverts —
    // otherwise the rule re-applies at record-start and clobbers the one-off.
    private var oneTimeBundleID: String?
    private var oneTimeModel: DictationModelOption?

    func setOneTimeModel(_ model: DictationModelOption, for bundleID: String) {
        oneTimeBundleID = bundleID
        oneTimeModel = model
    }

    func clearOneTimeModel(for bundleID: String) {
        if oneTimeBundleID == bundleID {
            oneTimeBundleID = nil
            oneTimeModel = nil
        }
    }

    /// Return and clear a pending one-time model for this app, if any.
    func consumeOneTimeModel(for bundleID: String) -> DictationModelOption? {
        guard oneTimeBundleID == bundleID, let model = oneTimeModel else { return nil }
        oneTimeBundleID = nil
        oneTimeModel = nil
        return model
    }
}

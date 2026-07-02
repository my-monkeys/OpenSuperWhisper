import Foundation
import Combine

/// Single source of truth **and** single mutation point for the active engine + model.
///
/// The app can change the active model from several places — the menu-bar "Model"
/// picker, the Settings model lists, and the context-aware auto-switch — so each one
/// must go through the same seam or they drift (the menu could set a model the open
/// Settings window never hears about). Every selection flows through `select(_:)`;
/// everything that needs to *know* the active model observes `active`. Persistence
/// lives in `AppPreferences` (via `ModelCatalog`); this is the observable façade over it.
///
/// This is also the seam a future "export / import settings profile" feature hangs off:
/// one place owns the selection, so one place can serialize/replay it.
@MainActor
final class ModelSelectionStore: ObservableObject {
    static let shared = ModelSelectionStore()

    /// The one active engine+model, mirrored from `AppPreferences`. `nil` only when no
    /// engine/model is configured yet (fresh install / remote with no model).
    @Published private(set) var active: DictationModelOption?

    private var observer: NSObjectProtocol?

    private init() {
        active = ModelCatalog.activeOption()
        // Keep in sync with any lower-level activation that doesn't go through `select`
        // yet — notably the context-aware auto-switch, which calls ModelCatalog.activate
        // at record-start. That posts `.modelSelectionDidChange`; refresh from it.
        observer = NotificationCenter.default.addObserver(
            forName: .modelSelectionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.active = ModelCatalog.activeOption() }
        }
    }

    /// Activate an engine+model — the one mutation point for model selection. Persists to
    /// AppPreferences, reloads the engine, and republishes `active`.
    func select(_ option: DictationModelOption) {
        ModelCatalog.activate(option)
        active = ModelCatalog.activeOption()
    }

    /// Re-read the active model from AppPreferences (after something outside the store
    /// changed it). Rarely needed — the notification observer covers the common cases.
    func refresh() {
        active = ModelCatalog.activeOption()
    }
}

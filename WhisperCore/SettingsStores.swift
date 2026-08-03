import Foundation
import Combine

/// Single source of truth **and** single mutation point for the dictation language.
///
/// Both the menu-bar Language picker and the Settings language picker change it — route both
/// through `select(_:)` so they can't drift (the same multi-writer problem `ModelSelectionStore`
/// solves for the active model). Persistence lives in `AppPreferences`; this is the observable
/// façade over it. Changes post `.appPreferencesLanguageChanged`, which the menu and an open
/// Settings window observe.
///
/// `select` is idempotent — a no-op (no write, no post) when the value is unchanged — so the
/// menu↔Settings sync observers can't ping-pong.
@MainActor
public final class LanguageStore: ObservableObject {
    public static let shared = LanguageStore()

    @Published public private(set) var language: String

    private var observer: NSObjectProtocol?

    private init() {
        language = AppPreferences.shared.whisperLanguage
        // Stay current if the language changes anywhere (defensive — all writers go through select).
        observer = NotificationCenter.default.addObserver(
            forName: .appPreferencesLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.language = AppPreferences.shared.whisperLanguage }
        }
    }

    public func select(_ code: String) {
        guard code != AppPreferences.shared.whisperLanguage else { return }
        AppPreferences.shared.whisperLanguage = code
        language = code
        NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
    }
}

/// Single source of truth **and** single mutation point for the Translate-to-English toggle.
///
/// The menu-bar toggle and the Settings toggle both flip it — route both through `set(_:)`/`toggle()`
/// so they stay in lockstep. Idempotent like `LanguageStore`; posts `.translateSettingDidChange`,
/// which an open Settings window observes (the menu rebuilds from `AppPreferences` on open).
@MainActor
public final class TranslateStore: ObservableObject {
    public static let shared = TranslateStore()

    @Published public private(set) var enabled: Bool

    private var observer: NSObjectProtocol?

    private init() {
        enabled = AppPreferences.shared.translateToEnglish
        observer = NotificationCenter.default.addObserver(
            forName: .translateSettingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enabled = AppPreferences.shared.translateToEnglish }
        }
    }

    public func set(_ value: Bool) {
        guard value != AppPreferences.shared.translateToEnglish else { return }
        AppPreferences.shared.translateToEnglish = value
        enabled = value
        NotificationCenter.default.post(name: .translateSettingDidChange, object: nil)
    }

    public func toggle() { set(!AppPreferences.shared.translateToEnglish) }
}

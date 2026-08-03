import Foundation
import KeyboardShortcuts
import WhisperCore

/// App-side home of the trigger/indicator preference migrations (master's #48/#72).
///
/// These three operations interpret AppKit-bound types (`RecordingTriggerSet`, `ModifierKey`,
/// `MouseButton`, `IndicatorLayout`, `KeyboardShortcuts.Name.toggleRecord`) that live in the app
/// target and cannot rise into the iOS-shared WhisperCore framework — so after the extraction
/// they no longer compile inside `AppPreferences.init`. The framework keeps the *storage*
/// (public plain-string prefs); the app owns the *typed interpretation*, mirroring the
/// protocol-inversion ruling for the LLM cleanup backend (PR #57).
///
/// Ordering: called from `AppDelegate.applicationWillFinishLaunching`. The only readers of
/// `recordingTriggers` (ShortcutManager) and `indicatorLayout` (IndicatorWindowManager) start
/// in `applicationDidFinishLaunching`, strictly after willFinish — so migration + conflict
/// resolution always land before a reader can observe unmigrated state. This is the same
/// willFinish-not-didFinish seam as the consent-seam and backend-provider wirings (an
/// openFiles-at-launch delivers between willFinish and didFinish).
extension AppPreferences {

    /// Runs the trigger/indicator preference upkeep in master's original init order:
    /// the two once-per-install migrations, then the every-launch conflict resolution.
    func migrateTriggerAndIndicatorPrefs() {
        migrateIndicatorLayout()
        migrateRecordingTriggers()
        resolveTriggerConflicts()
    }

    /// Carry the old independent indicator switches into one ordered layout, so an existing
    /// install keeps the bubble it had. Idempotent: only runs while the new key is unset.
    private func migrateIndicatorLayout() {
        guard indicatorLayout.isEmpty else { return }
        indicatorLayout = IndicatorLayout.migrated(
            meterMode: indicatorMeterMode,
            showStop: showStopButtonOnIndicator,
            showCancel: showCancelButtonOnIndicator).json
    }

    /// Carries the three single-slot trigger preferences into the list. Idempotent: only runs
    /// while the new key is unset. The old keys stay readable so a downgrade still finds them.
    private func migrateRecordingTriggers() {
        guard recordingTriggers.isEmpty else { return }
        recordingTriggers = RecordingTriggerSet.migrated(
            mouseRaw: mouseButtonHotkey,
            modifierRaw: modifierOnlyHotkey,
            shortcut: KeyboardShortcuts.getShortcut(for: .toggleRecord)).json
    }

    /// A key bound both as a recording trigger and as stop-and-submit can only do one of them:
    /// the router checks submit first, so the trigger silently stops starting anything. Installs
    /// that reached that state before the editor prevented it get the submit binding cleared,
    /// since the trigger list is the one the user sees as a list. (#48)
    private func resolveTriggerConflicts() {
        let set = RecordingTriggerSet.load(from: recordingTriggers)
        let clash = set.conflicts(
            modifier: ModifierKey(rawValue: submitModifierOnlyHotkey) ?? .none,
            mouse: MouseButton(rawValue: submitMouseButtonHotkey) ?? .none)
        if clash.modifier { submitModifierOnlyHotkey = ModifierKey.none.rawValue }
        if clash.mouse { submitMouseButtonHotkey = MouseButton.none.rawValue }
    }
}

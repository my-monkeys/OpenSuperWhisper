import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
    /// Re-pastes the last transcription. Deliberately unbound by default — it is opt-in, and
    /// claiming a global combination for every user isn't ours to do. ⌃⌘V is a natural pick: it
    /// sits next to ⌘V without colliding with it or with paste-and-match-style (⌥⇧⌘V).
    static let pasteLastTranscription = Self("pasteLastTranscription")
    /// Dictates, then presses Return once the text lands — the keyboard twin of the submit
    /// mouse button. Unbound by default: claiming a global combination for everyone isn't
    /// ours to do. (#50)
    static let toggleRecordAndSubmit = Self("toggleRecordAndSubmit")

    /// One registration handle per recorded key combination. Names are dynamic because the
    /// number of triggers is: the combinations themselves live in `recordingTriggers`, and
    /// these slots are only how the library is told about them. (#48)
    static func recordTriggerSlot(_ index: Int) -> Self { Self("recordTriggerSlot\(index)") }
    /// The same, for combinations in the hold-only list.
    static func holdTriggerSlot(_ index: Int) -> Self { Self("holdTriggerSlot\(index)") }
    /// Slots are cleared up to this index when the list shrinks, so a removed combination
    /// can't stay bound. Well above any realistic number of triggers.
    static let recordTriggerSlotLimit = 16
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false
    private var useMouseButtonHotkey = false

    /// True once the current recording has been latched, so releasing the trigger key no longer
    /// stops it.
    private var latched = false
    /// `systemUptime` of the previous trigger key-down, for double-tap detection.
    private var lastKeyDownTime: TimeInterval = 0
    private let doubleTapThreshold: TimeInterval = 0.35
    /// `systemUptime` of the current recording's start, for suppressing a stacked latch chime.
    private var recordingStartedUptime: TimeInterval = 0
    /// A latch landing sooner than this after the recording started would put its chime on top of
    /// the recording-start one — two beeps that read as a stutter, not as two events. Comfortably
    /// wider than the double-tap window, which is the case that produces it.
    static let latchSoundQuietWindow: TimeInterval = 0.6

    private init() {
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupRecordingTrigger()

        // The latch tap itself is started per recording (see startLatchTapIfEnabled);
        // only the callback is wired up front.
        LatchKeyMonitor.shared.onLatchKeyDown = { [weak self] in
            self?.handleLatchKey()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
        latched = false
        LatchKeyMonitor.shared.stop()
    }

    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
        // Turning the latch preference off mid-recording tears the tap down immediately;
        // turning it on mid-recording arms it for the recording already running.
        Task { @MainActor in
            if !AppPreferences.shared.latchRecordingWithSpace {
                LatchKeyMonitor.shared.stop()
            } else if self.activeVm != nil {
                LatchKeyMonitor.shared.start()
            }
        }
    }

    /// Arms the Space tap for the recording that just started. The tap's lifetime is the
    /// recording's lifetime — between recordings no tap exists, so an idle app is not in the
    /// path of anyone's keystrokes, and the tap callback needs no cross-thread "is a recording
    /// active?" flag: while the tap is up, the answer is yes by construction.
    @MainActor private func startLatchTapIfEnabled() {
        guard AppPreferences.shared.latchRecordingWithSpace else { return }
        LatchKeyMonitor.shared.start()
    }

    /// Space pressed while recording: latch it, or stop the recording if it is already latched.
    private func handleLatchKey() {
        Task { @MainActor in
            guard self.activeVm != nil else { return }
            if self.latched {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                LatchKeyMonitor.shared.stop()
            } else {
                self.enterLatch()
            }
        }
    }

    /// Pins the current recording so releasing the trigger key won't stop it, and says so: the
    /// indicator's dot swells and goes solid, optionally with the same chime the recording start
    /// uses. Without that feedback there is no way to tell it is safe to let go.
    @MainActor private func enterLatch() {
        guard !latched else { return }
        holdWorkItem?.cancel()
        holdWorkItem = nil
        holdMode = false
        latched = true
        IndicatorWindowManager.shared.setLatched(true)

        let sinceStart = ProcessInfo.processInfo.systemUptime - recordingStartedUptime
        if AppPreferences.shared.playSoundOnRecordStart,
           Self.shouldPlayLatchSound(sinceRecordingStart: sinceStart) {
            AudioRecorder.shared.playNotificationSound()
        }
    }

    /// Whether this trigger press is the second half of a double-tap. Pure so the timing rule can
    /// be tested without an event tap.
    static func isDoubleTap(now: TimeInterval, previous: TimeInterval, threshold: TimeInterval) -> Bool {
        now - previous < threshold
    }

    /// Whether the latch deserves its own chime.
    ///
    /// Latching by double-tap happens within a few hundred milliseconds of the recording starting,
    /// so its chime would land on top of the recording-start one and read as a stutter rather than
    /// as confirmation of a second thing. Latching later — the hold-then-Space case, where the
    /// recording has been running a while and you may not be looking at the indicator — is exactly
    /// when the sound earns its place.
    static func shouldPlayLatchSound(sinceRecordingStart: TimeInterval,
                                     quietWindow: TimeInterval = latchSoundQuietWindow) -> Bool {
        sinceRecordingStart >= quietWindow
    }
    
    private func setupKeyboardShortcuts() {
        // Self-heal a cleared cancel shortcut: KeyboardShortcuts' `default:` only applies when
        // the key is ABSENT from UserDefaults; a stored-empty value (`false`) overrides it, which
        // leaves cancel-on-Esc silently dead — and there's no UI to re-enable it. Restore the
        // default Esc when nothing is bound.
        if KeyboardShortcuts.getShortcut(for: .escape) == nil {
            KeyboardShortcuts.setShortcut(.init(.escape), for: .escape)
        }

        // One pair of handlers per slot, registered once for the process lifetime.
        for index in 0..<KeyboardShortcuts.Name.recordTriggerSlotLimit {
            let slot = KeyboardShortcuts.Name.recordTriggerSlot(index)
            KeyboardShortcuts.onKeyDown(for: slot) { [weak self] in self?.handleKeyDown() }
            KeyboardShortcuts.onKeyUp(for: slot) { [weak self] in self?.handleKeyUp() }
            let holdSlot = KeyboardShortcuts.Name.holdTriggerSlot(index)
            KeyboardShortcuts.onKeyDown(for: holdSlot) { [weak self] in self?.handleKeyDown(holdOnly: true) }
            KeyboardShortcuts.onKeyUp(for: holdSlot) { [weak self] in self?.handleKeyUp(holdOnly: true) }
        }

        // Ends the running take and submits it. Works alongside every trigger mode, since it is
        // a shortcut of its own, and never starts a recording. (#50)
        KeyboardShortcuts.onKeyDown(for: .toggleRecordAndSubmit) { [weak self] in
            self?.handleSubmitKey()
        }

        // On key-UP: the handler waits for the modifiers to lift before synthesizing ⌘V, and
        // starting that wait only once the key is released keeps a held-down shortcut from
        // firing repeatedly.
        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscription) {
            Task { @MainActor in
                await PasteLastTranscript.run()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                // requestCancel() discards immediately for short recordings, but a long
                // one arms a confirmation and returns false — leave activeVm set so the
                // next Esc (within the window) confirms the cancel.
                if self?.activeVm != nil, IndicatorWindowManager.shared.requestCancel() {
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }
    
    private func setupRecordingTrigger() {
        let set = RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers)
        let holdSet = RecordingTriggerSet.load(from: AppPreferences.shared.holdRecordingTriggers)
        // Optional second bindings that dictate and then submit. Separate from the trigger list:
        // they end a take rather than starting one. (#50)
        let submitButton = MouseButton(rawValue: AppPreferences.shared.submitMouseButtonHotkey) ?? .none
        let submitModifier = ModifierKey(rawValue: AppPreferences.shared.submitModifierOnlyHotkey) ?? .none
        let submitChord = ModifierChord(storageValue: AppPreferences.shared.submitModifierChord)
        let triggerChords = set.chords

        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        let mouseButtons = set.mouseButtons + holdSet.mouseButtons + (submitButton == .none ? [] : [submitButton])
        if !mouseButtons.isEmpty {
            MouseButtonMonitor.shared.onButtonDown = { [weak self] button in
                guard let self else { return }
                if submitButton != .none, button == submitButton {
                    self.handleSubmitKey()
                } else {
                    self.handleKeyDown(holdOnly: holdSet.mouseButtons.contains(button))
                }
            }
            MouseButtonMonitor.shared.onButtonUp = { [weak self] button in
                guard submitButton == .none || button != submitButton else { return }
                self?.handleKeyUp(holdOnly: holdSet.mouseButtons.contains(button))
            }
            MouseButtonMonitor.shared.start(mouseButtons: mouseButtons)
        }

        let modifiers = set.modifiers + holdSet.modifiers + (submitModifier == .none ? [] : [submitModifier])
        let chords = triggerChords + (submitChord.map { [$0] } ?? [])
        // A chord fires once, on release, so it acts as a tap: toggle a recording, or submit.
        // Hold-to-record has no meaning for it.
        ModifierKeyMonitor.shared.onChord = { [weak self] chord in
            guard let self else { return }
            if chord == submitChord {
                self.handleSubmitKey()
            } else if triggerChords.contains(chord) {
                self.handleKeyDown()
                self.handleKeyUp()
            }
        }
        if !modifiers.isEmpty || !chords.isEmpty {
            ModifierKeyMonitor.shared.onKeyDown = { [weak self] key in
                guard let self else { return }
                if submitModifier != .none, key == submitModifier {
                    self.handleSubmitKey()
                } else {
                    self.handleKeyDown(holdOnly: holdSet.modifiers.contains(key))
                }
            }
            ModifierKeyMonitor.shared.onKeyUp = { [weak self] key in
                guard submitModifier == .none || key != submitModifier else { return }
                self?.handleKeyUp(holdOnly: holdSet.modifiers.contains(key))
            }
            ModifierKeyMonitor.shared.start(modifierKeys: modifiers, chords: chords)
        }

        bindKeyComboSlots(set.keyCombos, to: KeyboardShortcuts.Name.recordTriggerSlot)
        bindKeyComboSlots(holdSet.keyCombos, to: KeyboardShortcuts.Name.holdTriggerSlot)

        useMouseButtonHotkey = !set.mouseButtons.isEmpty || !holdSet.mouseButtons.isEmpty
        useModifierOnlyHotkey = !set.modifiers.isEmpty || !holdSet.modifiers.isEmpty || !chords.isEmpty
        print("ShortcutManager: \(set.triggers.count) recording trigger(s), \(holdSet.triggers.count) hold-only, armed")
    }

    /// Points one library slot at each recorded combination and clears the rest, so removing a
    /// trigger actually unbinds it rather than leaving a stale slot listening.
    ///
    /// Only the bindings move here. The handlers are registered once at launch, because
    /// `KeyboardShortcuts.onKeyDown` appends to a list rather than replacing: re-registering on
    /// every settings change stacked duplicates, and one key press then ran the toggle twice —
    /// starting a recording and immediately ending it, which looked like the mic firing with no
    /// indicator.
    private func bindKeyComboSlots(_ combos: [KeyboardShortcuts.Shortcut],
                                   to slotName: (Int) -> KeyboardShortcuts.Name) {
        for index in 0..<KeyboardShortcuts.Name.recordTriggerSlotLimit {
            let slot = slotName(index)
            if index < combos.count {
                KeyboardShortcuts.setShortcut(combos[index], for: slot)
                KeyboardShortcuts.enable(slot)
            } else {
                KeyboardShortcuts.setShortcut(nil, for: slot)
                KeyboardShortcuts.disable(slot)
            }
        }
    }

    /// Stops the running take and asks for Return once its text lands. Deliberately cannot
    /// START a recording: one key begins a dictation, the others only end it. Both keys being
    /// able to do both made the outcome depend on which one you happened to press first, which
    /// is invisible from the outside. (#50)
    private func handleSubmitKey() {
        endActiveTake(submit: true)
    }

    /// Starts a recording, or stops the one running, as one press of the trigger would. For the
    /// agent panel's Dictate button.
    @MainActor func toggleRecordingFromApp(showBubble: Bool = true) {
        if activeVm == nil, !showBubble {
            IndicatorWindowManager.shared.hideNextBubble = true
        }
        handleKeyDown()
        handleKeyUp()
    }

    /// Discards the running take, without the confirmation Esc asks for on a long one: this is
    /// a button the user aimed at, not a key that may have been brushed.
    func cancelRecordingFromApp() {
        Task { @MainActor in
            guard self.activeVm != nil else { return }
            IndicatorWindowManager.shared.stopForce()
            self.activeVm = nil
            self.holdMode = false
            LatchKeyMonitor.shared.stop()
        }
    }

    /// The stop phrase was heard at the end of the live transcript: end the take the way the
    /// trigger would, through here so the hold and latch state is cleared with it. (#145)
    func endTakeOnStopPhrase() {
        endActiveTake(submit: AppPreferences.shared.stopPhraseSubmits)
    }

    private func endActiveTake(submit: Bool) {
        Task { @MainActor in
            // Nothing to end: these have no meaning outside a recording.
            guard let vm = self.activeVm else { return }
            if submit { vm.submitAfterInsert = true }
            self.holdWorkItem?.cancel()
            self.holdWorkItem = nil
            self.holdMode = false
            IndicatorWindowManager.shared.stopRecording()
            self.activeVm = nil
        }
    }

    /// `holdOnly` is for the hold-only triggers: the recording lasts exactly as long as the key
    /// is down, with no tap-to-toggle window, whatever `holdToRecord` says.
    private func handleKeyDown(holdOnly: Bool = false) {
        holdWorkItem?.cancel()
        holdMode = false

        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = AppPreferences.shared.latchRecordingWithSpace
            && Self.isDoubleTap(now: now, previous: lastKeyDownTime, threshold: doubleTapThreshold)
        lastKeyDownTime = now

        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        if holdOnly { holdMode = true }

        Task { @MainActor in
            if self.activeVm == nil {
                Diag.mark("keyDown → start recording")
                // Pressed while the agent panel has focus: the take answers the agent there,
                // and the panel shows the recording instead of the bubble.
                if AgentInbox.shared.claimTrigger() {
                    IndicatorWindowManager.shared.hideNextBubble = true
                }
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                var caret: CGRect? = nil
                // Only "cursor" mode needs the caret; other positions anchor to
                // screen geometry, so skip the synchronous AX caret query (a
                // main-thread hang risk) when its result would be discarded.
                if FocusUtils.shouldAnchorToCaret(indicatorPosition: AppPreferences.shared.indicatorPosition) {
                    caret = Diag.measure("getCaretRect") { FocusUtils.getCaretRect() }
                }
                let indicatorPoint: NSPoint? = caret.map { FocusUtils.convertAXPointToCocoa($0.origin) } ?? cursorPosition
                let vm = Diag.measure("IndicatorWindowManager.show") {
                    IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                }
                Diag.measure("vm.startRecording") { vm.startRecording() }
                self.activeVm = vm
                self.recordingStartedUptime = ProcessInfo.processInfo.systemUptime
                self.startLatchTapIfEnabled()
            } else if isDoubleTap && !self.latched {
                // Second tap of a double-tap latches the recording the first tap started, rather
                // than immediately stopping it — the same gesture as Space, without leaving the
                // trigger key.
                self.enterLatch()
            } else if !self.holdMode || self.latched {
                // A latched recording no longer follows the held key, so pressing a hold trigger
                // again stops it, same as a toggle.
                //
                // Paired with "keyDown → start recording": a stop that is missing from the log
                // never reached the app, which is a different bug from one that reached it and
                // did nothing.
                Diag.mark("keyDown → stop recording")
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
                LatchKeyMonitor.shared.stop()
            }
        }
        
        if holdToRecordEnabled && !holdOnly {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }
    
    private func handleKeyUp(holdOnly: Bool = false) {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord || holdOnly
        
        Task { @MainActor in
            // A latched recording ignores the trigger key coming back up — that is the whole point
            // — and waits for Space (or the trigger) to stop it.
            if holdToRecordEnabled && self.holdMode && !self.latched {
                Diag.mark("keyUp → stop recording (hold)")
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                LatchKeyMonitor.shared.stop()
                self.holdMode = false
            }
        }
    }
}
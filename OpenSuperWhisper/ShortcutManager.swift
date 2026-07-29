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
    /// Read on the latch monitor's tap thread to decide whether to swallow Space. Mirrors
    /// "a recording is currently active".
    private var recordingActive = false
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
        setupLatchMonitor()

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
        recordingActive = false
    }

    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
        setupLatchMonitor()
    }

    /// Starts or stops the Space-latch tap to match the preference. Unlike the three trigger modes
    /// this one is mode-agnostic — it only ever acts while a recording is running — so it can stay
    /// armed for the whole app lifetime once enabled.
    private func setupLatchMonitor() {
        guard AppPreferences.shared.latchRecordingWithSpace else {
            LatchKeyMonitor.shared.stop()
            return
        }

        LatchKeyMonitor.shared.shouldConsume = { [weak self] in
            self?.recordingActive ?? false
        }
        LatchKeyMonitor.shared.onLatchKeyDown = { [weak self] in
            self?.handleLatchKey()
        }
        LatchKeyMonitor.shared.start()
    }

    /// Space pressed while recording: latch it, or stop the recording if it is already latched.
    private func handleLatchKey() {
        Task { @MainActor in
            guard self.activeVm != nil else { return }
            if self.latched {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.recordingActive = false
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

        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
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
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none

        // The three trigger modes are mutually exclusive. Tear all of them down
        // first, then enable exactly one. A configured mouse button takes priority
        // over a modifier key, which takes priority over the regular shortcut.
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        if mouseButton != .none {
            useMouseButtonHotkey = true
            useModifierOnlyHotkey = false
            KeyboardShortcuts.disable(.toggleRecord)

            MouseButtonMonitor.shared.onButtonDown = { [weak self] in
                self?.handleKeyDown()
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] in
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButton: mouseButton)
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        } else if modifierKey != .none {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }

            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName)")
        } else {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = false
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false

        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = AppPreferences.shared.latchRecordingWithSpace
            && Self.isDoubleTap(now: now, previous: lastKeyDownTime, threshold: doubleTapThreshold)
        lastKeyDownTime = now

        let holdToRecordEnabled = AppPreferences.shared.holdToRecord

        Task { @MainActor in
            if self.activeVm == nil {
                Diag.mark("keyDown → start recording")
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
                self.recordingActive = true
                self.recordingStartedUptime = ProcessInfo.processInfo.systemUptime
            } else if isDoubleTap && !self.latched {
                // Second tap of a double-tap latches the recording the first tap started, rather
                // than immediately stopping it — the same gesture as Space, without leaving the
                // trigger key.
                self.enterLatch()
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.recordingActive = false
            }
        }
        
        if holdToRecordEnabled {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            // A latched recording ignores the trigger key coming back up — that is the whole point
            // — and waits for Space (or the trigger) to stop it.
            if holdToRecordEnabled && self.holdMode && !self.latched {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.recordingActive = false
                self.holdMode = false
            }
        }
    }
}
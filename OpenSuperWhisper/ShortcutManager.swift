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
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false
    private var useMouseButtonHotkey = false

    private init() {
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupRecordingTrigger()
        
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
    }
    
    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
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
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none
        // Optional second button that dictates and then submits. It works alongside whichever
        // trigger is active, including the keyboard ones, so it is set up separately. (#50)
        let submitButton = MouseButton(rawValue: AppPreferences.shared.submitMouseButtonHotkey) ?? .none
        let submitModifier = ModifierKey(rawValue: AppPreferences.shared.submitModifierOnlyHotkey) ?? .none

        // The three trigger modes are mutually exclusive. Tear all of them down
        // first, then enable exactly one. A configured mouse button takes priority
        // over a modifier key, which takes priority over the regular shortcut.
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        if mouseButton != .none || submitButton != .none {
            useMouseButtonHotkey = mouseButton != .none
            if mouseButton != .none {
                useModifierOnlyHotkey = false
                // Only the plain record shortcut is exclusive with the other trigger modes;
                // toggleRecordAndSubmit is a separate action and stays live.
                KeyboardShortcuts.disable(.toggleRecord)
            }

            MouseButtonMonitor.shared.onButtonDown = { [weak self] button in
                guard let self else { return }
                if submitButton != .none, button == submitButton {
                    self.handleSubmitKey()
                } else {
                    self.handleKeyDown()
                }
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] button in
                guard submitButton == .none || button != submitButton else { return }
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButtons: [mouseButton, submitButton])
        }

        if mouseButton != .none {
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        }

        if modifierKey != .none || submitModifier != .none {
            useModifierOnlyHotkey = modifierKey != .none
            if modifierKey != .none && mouseButton == .none {
                useMouseButtonHotkey = false
                KeyboardShortcuts.disable(.toggleRecord)
            }

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] key in
                guard let self else { return }
                if submitModifier != .none, key == submitModifier {
                    self.handleSubmitKey()
                } else {
                    self.handleKeyDown()
                }
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] key in
                // The submit key already stopped the take on key-down; a release must not
                // stop a fresh recording started right after.
                guard submitModifier == .none || key != submitModifier else { return }
                self?.handleKeyUp()
            }

            ModifierKeyMonitor.shared.start(modifierKeys: [modifierKey, submitModifier])
        }

        if mouseButton != .none {
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        } else if modifierKey != .none {
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName)")
        } else {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = false
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    /// Stops the running take and asks for Return once its text lands. Deliberately cannot
    /// START a recording: one key begins a dictation, the others only end it. Both keys being
    /// able to do both made the outcome depend on which one you happened to press first, which
    /// is invisible from the outside. (#50)
    private func handleSubmitKey() {
        Task { @MainActor in
            // Nothing to submit: this key has no meaning outside a recording.
            guard let vm = self.activeVm else { return }
            vm.submitAfterInsert = true
            self.holdWorkItem?.cancel()
            self.holdWorkItem = nil
            self.holdMode = false
            IndicatorWindowManager.shared.stopRecording()
            self.activeVm = nil
        }
    }

    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false
        
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
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
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
            if holdToRecordEnabled && self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
            }
        }
    }
}
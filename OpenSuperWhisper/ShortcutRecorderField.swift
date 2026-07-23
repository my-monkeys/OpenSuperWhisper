import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// The combo rule the recorder enforces, kept pure so it's unit-testable.
/// A shortcut needs at least one of ⌘ ⌥ ⌃ (⇧ alone can't be a global hotkey),
/// except function keys, which work bare (F5 as a dictation trigger).
enum RecorderCombo {
    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
        kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
        kVK_F18, kVK_F19, kVK_F20,
    ]

    static func isValid(modifiers: NSEvent.ModifierFlags, keyCode: Int) -> Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
            || functionKeyCodes.contains(keyCode)
    }
}

/// Atelier-styled shortcut recorder replacing `KeyboardShortcuts.Recorder`,
/// which renders as a bare search field and gives no feedback while keys are
/// held. Click to arm, and the ⌃ ⌥ ⇧ ⌘ badges light up live as modifiers are
/// pressed; a valid combo is saved through `KeyboardShortcuts.setShortcut`, so
/// the Carbon hotkey engine underneath is unchanged. Esc cancels, ⌫ clears,
/// clicking anywhere else disarms.
struct ShortcutRecorderField: View {
    let name: KeyboardShortcuts.Name

    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var isRecording = false
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var invalidCombo = false
    @State private var isHovering = false
    @State private var monitors: [Any] = []

    private static let badges: [(flag: NSEvent.ModifierFlags, symbol: String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                recordingBody
            } else {
                idleBody
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(isRecording ? STheme.accentSoft : STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(invalidCombo ? STheme.warn : (isRecording ? STheme.accent : STheme.controlBorder), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { if isRecording { disarm() } else { arm() } }
        .onHover { isHovering = $0 }
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: name) }
        .onDisappear { disarm() }
        .animation(.easeOut(duration: 0.12), value: heldModifiers.rawValue)
        .animation(.easeOut(duration: 0.12), value: isRecording)
    }

    private var idleBody: some View {
        HStack(spacing: 6) {
            if let shortcut {
                Text(shortcut.description)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(STheme.textBright)
                Spacer(minLength: 0)
                if isHovering {
                    Button {
                        KeyboardShortcuts.setShortcut(nil, for: name)
                        self.shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(STheme.hint)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
            } else {
                Text("Click to record")
                    .font(.system(size: 11))
                    .foregroundColor(STheme.hint)
                Spacer(minLength: 0)
            }
        }
    }

    private var recordingBody: some View {
        HStack(spacing: 4) {
            ForEach(Self.badges, id: \.symbol) { badge in
                let held = heldModifiers.contains(badge.flag)
                Text(badge.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(held ? .white : STheme.hint)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(held ? STheme.accent : STheme.controlBg))
            }
            Text(invalidCombo ? "add ⌘ ⌥ or ⌃" : "key…")
                .font(.system(size: 11))
                .foregroundColor(invalidCombo ? STheme.warn : STheme.hint)
                .padding(.leading, 2)
            Spacer(minLength: 0)
        }
    }

    private func arm() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        invalidCombo = false
        // Pause the live hotkey so re-recording the current combo doesn't
        // toggle a dictation mid-capture.
        KeyboardShortcuts.isEnabled = false

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            heldModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if invalidCombo, !heldModifiers.intersection([.command, .option, .control]).isEmpty {
                invalidCombo = false
            }
            return event
        }!)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting(.function)
            if modifiers.isEmpty {
                switch Int(event.keyCode) {
                case kVK_Escape:
                    disarm()
                    return nil
                case kVK_Delete, kVK_ForwardDelete:
                    KeyboardShortcuts.setShortcut(nil, for: name)
                    shortcut = nil
                    disarm()
                    return nil
                case kVK_Tab:
                    disarm()
                    return event
                default:
                    break
                }
            }
            guard RecorderCombo.isValid(modifiers: modifiers, keyCode: Int(event.keyCode)),
                  let captured = KeyboardShortcuts.Shortcut(event: event)
            else {
                NSSound.beep()
                invalidCombo = true
                return nil
            }
            KeyboardShortcuts.setShortcut(captured, for: name)
            shortcut = captured
            disarm()
            return nil
        }!)

        // A click outside the field disarms; a click on it is handled by the
        // tap gesture (toggle), so only forward those.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !isHovering { disarm() }
            return event
        }!)
    }

    private func disarm() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        KeyboardShortcuts.isEnabled = true
        isRecording = false
        heldModifiers = []
        invalidCombo = false
    }
}

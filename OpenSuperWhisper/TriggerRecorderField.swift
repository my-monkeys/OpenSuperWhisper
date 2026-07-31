import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// Records the recording trigger: a key combination, a single modifier, or a mouse button,
/// whichever the user performs. One field instead of a mode picker plus three per-mode controls.
///
/// Click to arm, then do the thing you want as your trigger: press ⌃⌥D, tap Right ⌥ on its own,
/// or click a spare mouse button. Esc cancels, ⌫ clears.
struct TriggerRecorderField: View {
    /// Where this field stores what it records. Three actions use the same widget: start a
    /// recording, dictate-and-submit, and cancel.
    let name: KeyboardShortcuts.Name
    @Binding var mouseButton: MouseButton
    @Binding var modifierKey: ModifierKey
    /// Mouse buttons make no sense for some actions (cancel is a keyboard reflex, and binding
    /// a spare button to it would collide with the record trigger's own button).
    var allowsMouse = true
    /// A lone modifier is a fine way to start a recording but a poor way to cancel one, so the
    /// cancel field turns it off.
    var allowsModifier = true
    /// Cancel is normally bound to bare Esc, so that field has to be able to record it. Esc then
    /// can't also mean "abort the capture" there; clicking outside does that instead.
    var allowsBareEscape = false

    @State private var isRecording = false
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var isHovering = false
    @State private var monitors: [Any] = []
    @State private var detector = SingleModifierDetector()

    private var trigger: RecordingTrigger {
        RecordingTrigger.resolve(
            mouseRaw: mouseButton.rawValue,
            modifierRaw: modifierKey.rawValue,
            shortcut: KeyboardShortcuts.getShortcut(for: name))
    }

    var body: some View {
        HStack(spacing: 8) {
            if isRecording { recordingBody } else { idleBody }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isRecording ? STheme.accentSoft : STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isRecording ? STheme.accent : STheme.controlBorder, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { if isRecording { disarm() } else { arm() } }
        .onHover { isHovering = $0 }
        .onDisappear { disarm() }
        .animation(.easeOut(duration: 0.12), value: heldModifiers.rawValue)
        .animation(.easeOut(duration: 0.12), value: isRecording)
    }

    private var idleBody: some View {
        HStack(spacing: 6) {
            let caps = trigger.caps
            if caps.isEmpty {
                Text("Click to record")
                    .font(.system(size: 11))
                    .foregroundColor(STheme.hint)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                        TriggerCap(label: cap)
                    }
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button { clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(STheme.hint)
                    }
                    .buttonStyle(.plain)
                    .help("Clear trigger")
                }
            }
        }
    }

    private var recordingBody: some View {
        HStack(spacing: 4) {
            ForEach(RecordingTrigger.modifierBadges, id: \.symbol) { badge in
                let held = heldModifiers.contains(badge.flag)
                Text(badge.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(held ? .white : STheme.hint)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(held ? STheme.accent : STheme.controlBg))
            }
            Text(placeholder)
                .font(.system(size: 11))
                .foregroundColor(STheme.hint)
                .padding(.leading, 2)
            Spacer(minLength: 0)
        }
    }

    private var placeholder: String {
        switch (allowsModifier, allowsMouse) {
        case (true, true): return "key, modifier or mouse…"
        case (true, false): return "key or modifier…"
        default: return "key combination…"
        }
    }

    // MARK: - Capture

    private func arm() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        detector.reset()
        // Pause live hotkeys so re-recording the current trigger doesn't start a dictation.
        KeyboardShortcuts.isEnabled = false
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            heldModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if let key = detector.handleFlagsChanged(keyCode: event.keyCode,
                                                     flags: event.modifierFlags), allowsModifier {
                save(.modifier(key))
            }
            return event
        }!)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            detector.contaminate()
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting(.function)
            if modifiers.isEmpty {
                switch Int(event.keyCode) {
                case kVK_Escape where !allowsBareEscape:
                    disarm()
                    return nil
                case kVK_Escape:
                    if let captured = KeyboardShortcuts.Shortcut(event: event) {
                        save(.keyCombo(captured))
                    }
                    return nil
                case kVK_Delete, kVK_ForwardDelete:
                    clear()
                    disarm()
                    return nil
                case kVK_Tab:
                    disarm()
                    return event
                default:
                    break
                }
            }
            // Esc with modifiers (⌘Esc, ⌥Esc) is a normal combination for a cancel binding.
            let escapeCombo = allowsBareEscape && Int(event.keyCode) == kVK_Escape
            guard escapeCombo || RecorderCombo.isValid(modifiers: modifiers, keyCode: Int(event.keyCode)),
                  let captured = KeyboardShortcuts.Shortcut(event: event)
            else {
                NSSound.beep()
                return nil
            }
            save(.keyCombo(captured))
            return nil
        }!)

        // Spare mouse buttons only. Left and right click stay ordinary clicks: binding them
        // would take the pointer away from the user.
        if allowsMouse {
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
                guard let button = MouseButton.allCases.first(where: {
                    $0 != .none && $0.buttonNumber == Int64(event.buttonNumber)
                }) else {
                    NSSound.beep()
                    return nil
                }
                save(.mouse(button))
                return nil
            }!)
        }

        // A click outside the field disarms; a click on it is handled by the tap gesture.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !isHovering { disarm() }
            return event
        }!)
    }

    /// Stores the trigger, clearing the other two kinds: exactly one is active at a time, which
    /// is what makes the mode implicit.
    private func save(_ trigger: RecordingTrigger) {
        switch trigger {
        case .none:
            clear()
        case .keyCombo(let shortcut):
            mouseButton = .none
            modifierKey = .none
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        case .modifier(let key):
            mouseButton = .none
            modifierKey = key
            KeyboardShortcuts.setShortcut(nil, for: name)
        case .mouse(let button):
            modifierKey = .none
            mouseButton = button
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
        disarm()
    }

    private func clear() {
        mouseButton = .none
        modifierKey = .none
        KeyboardShortcuts.setShortcut(nil, for: name)
    }

    private func disarm() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        detector.reset()
        KeyboardShortcuts.isEnabled = true
        isRecording = false
        heldModifiers = []
        // Rebuild whichever monitor the stored trigger needs.
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }
}

/// A trigger drawn as a cap. Wider than the shortcut field's, since a modifier or mouse button
/// spells out its name ("Right ⌥ Option") rather than showing one glyph.
private struct TriggerCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(STheme.textBright)
            .lineLimit(1)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, label.count > 1 ? 5 : 0)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(STheme.controlBorder, lineWidth: 0.5))
    }
}

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
    /// The record trigger keeps a list: any number of combinations, modifiers and buttons, all
    /// live at once (#48). The other actions hold one binding, so recording replaces it.
    var allowsMultiple = false

    /// Mirrors the stored shortcut. `KeyboardShortcuts.getShortcut` is not something SwiftUI
    /// observes, so reading it straight from the body left a newly recorded combination
    /// invisible until something else redrew the view — the whole list looked broken.
    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var isRecording = false
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var isHovering = false
    @State private var monitors: [Any] = []
    @State private var detector = SingleModifierDetector()

    /// The stored list, for the multi-trigger field. Mirrored in state so a change redraws:
    /// preferences are not something SwiftUI observes.
    @State private var set = RecordingTriggerSet.empty

    private var triggers: [RecordingTrigger] {
        guard allowsMultiple else {
            let single = RecordingTrigger.resolve(mouseRaw: mouseButton.rawValue,
                                                  modifierRaw: modifierKey.rawValue,
                                                  shortcut: shortcut)
            return single == .none ? [] : [single]
        }
        return set.triggers
    }

    private func loadShortcut() {
        shortcut = KeyboardShortcuts.getShortcut(for: name)
        if allowsMultiple {
            set = RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers)
        }
    }

    private func persistSet() {
        AppPreferences.shared.recordingTriggers = set.json
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }

    @ViewBuilder var body: some View {
        if allowsMultiple {
            listBody
        } else {
            singleField
        }
    }

    /// One row per configured trigger, plus an explicit row to add another. The compact field
    /// couldn't show two bindings side by side without cramming, and its "+" was decoration
    /// rather than a control — clicking it armed the recorder by accident rather than by design.
    private var listBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(triggers.enumerated()), id: \.offset) { _, configured in
                triggerRow(configured)
            }
            addRow
        }
    }

    private func triggerRow(_ trigger: RecordingTrigger) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(trigger.caps.enumerated()), id: \.offset) { _, cap in
                    TriggerCap(label: cap)
                }
            }
            Spacer(minLength: 8)
            Button { remove(trigger) } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
            }
            .buttonStyle(.plain)
            .pointerCursorOnHover()
            .help("Remove this trigger")
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
    }

    /// Doubles as the capture surface: idle it invites a new trigger, armed it shows the
    /// modifiers being held, so the thing you click is the thing that records.
    private var addRow: some View {
        HStack(spacing: 8) {
            if isRecording {
                ForEach(RecordingTrigger.modifierBadges, id: \.symbol) { badge in
                    let held = heldModifiers.contains(badge.flag)
                    Text(badge.symbol)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundColor(held ? .white : STheme.hint)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(held ? STheme.accent : STheme.controlBg))
                }
                Text(placeholder)
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
            } else {
                Image(systemName: "plus")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundColor(STheme.hint)
                Text(triggers.isEmpty ? "Add a trigger" : "Add another")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isRecording ? STheme.accentSoft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isRecording ? STheme.accent : STheme.controlBorder,
                          style: StrokeStyle(lineWidth: 1, dash: isRecording ? [] : [4, 3])))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { if isRecording { disarm() } else { arm() } }
        .onHover { isHovering = $0 }
        .pointerCursorOnHover()
        .onAppear { loadShortcut() }
        .onDisappear { disarm() }
        .animation(.easeOut(duration: 0.12), value: heldModifiers.rawValue)
        .animation(.easeOut(duration: 0.12), value: isRecording)
    }

    private var singleField: some View {
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
        .onAppear { loadShortcut() }
        .onDisappear { disarm() }
        .animation(.easeOut(duration: 0.12), value: heldModifiers.rawValue)
        .animation(.easeOut(duration: 0.12), value: isRecording)
    }

    /// The single-binding presentation: one trigger, replaced on each recording.
    private var idleBody: some View {
        HStack(spacing: 6) {
            if let configured = triggers.first {
                HStack(spacing: 3) {
                    ForEach(Array(configured.caps.enumerated()), id: \.offset) { _, cap in
                        TriggerCap(label: cap)
                    }
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button { clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 11)
                            .foregroundColor(STheme.hint)
                    }
                    .buttonStyle(.plain)
                    .help("Clear trigger")
                }
            } else {
                Text("Click to record")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
                Spacer(minLength: 0)
            }
        }
    }

    /// Clears one trigger without touching the others.
    private func remove(_ trigger: RecordingTrigger) {
        guard allowsMultiple else {
            clear()
            return
        }
        set.remove(trigger)
        persistSet()
    }

    private var recordingBody: some View {
        HStack(spacing: 4) {
            ForEach(RecordingTrigger.modifierBadges, id: \.symbol) { badge in
                let held = heldModifiers.contains(badge.flag)
                Text(badge.symbol)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundColor(held ? .white : STheme.hint)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(held ? STheme.accent : STheme.controlBg))
            }
            Text(placeholder)
                .scaledFont(size: 11)
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
        if allowsMultiple {
            set.add(trigger)
            releaseFromOtherActions(trigger)
            persistSet()
            disarm()
            return
        }
        // The reverse direction: binding a key to this action takes it off the trigger list, or
        // the router would route it here and the trigger would silently stop starting anything.
        takeOverFromRecordingTriggers(trigger)
        switch trigger {
        case .none:
            clear()
        case .keyCombo(let shortcut):
            if !allowsMultiple { mouseButton = .none; modifierKey = .none }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            self.shortcut = shortcut
        case .modifier(let key):
            if !allowsMultiple {
                mouseButton = .none
                KeyboardShortcuts.setShortcut(nil, for: name)
                self.shortcut = nil
            }
            modifierKey = key
        case .mouse(let button):
            if !allowsMultiple {
                modifierKey = .none
                KeyboardShortcuts.setShortcut(nil, for: name)
                self.shortcut = nil
            }
            mouseButton = button
        }
        disarm()
    }

    /// Frees a key that another action already claims. The newest assignment wins, which is what
    /// every shortcut editor does — the alternative is a key bound twice where the loser fails
    /// silently, which is exactly how a working modifier looked broken.
    private func releaseFromOtherActions(_ trigger: RecordingTrigger) {
        let prefs = AppPreferences.shared
        switch trigger {
        case .modifier(let key):
            if prefs.submitModifierOnlyHotkey == key.rawValue {
                prefs.submitModifierOnlyHotkey = ModifierKey.none.rawValue
            }
        case .mouse(let button):
            if prefs.submitMouseButtonHotkey == button.rawValue {
                prefs.submitMouseButtonHotkey = MouseButton.none.rawValue
            }
        case .keyCombo, .none:
            break
        }
    }

    /// Same rule, applied when a single-binding field claims something the trigger list holds.
    private func takeOverFromRecordingTriggers(_ trigger: RecordingTrigger) {
        var triggerSet = RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers)
        guard triggerSet.triggers.contains(trigger) else { return }
        triggerSet.remove(trigger)
        AppPreferences.shared.recordingTriggers = triggerSet.json
    }

    private func clear() {
        mouseButton = .none
        modifierKey = .none
        KeyboardShortcuts.setShortcut(nil, for: name)
        shortcut = nil
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
            .scaledFont(size: 11.5, weight: .semibold)
            .foregroundColor(STheme.textBright)
            .lineLimit(1)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, label.count > 1 ? 5 : 0)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(STheme.controlBorder, lineWidth: 0.5))
    }
}

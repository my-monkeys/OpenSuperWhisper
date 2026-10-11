import SwiftUI
import AppKit

// Building blocks of the v3 redesign. Every page and settings rubric is assembled from these so
// that type sizes, spacing and colours stay in one place: labels 15 pt, help 13 pt, page titles
// 26 to 30 pt, rows at least 56 pt tall, groups as cream cards with hairline separators.

// MARK: - Advanced options

private struct ShowsAdvancedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether rows marked `advanced` are shown. Set by `RubricPage` from its Advanced switch;
    /// true everywhere else, so a row reused outside the settings never disappears.
    var showsAdvanced: Bool {
        get { self[ShowsAdvancedKey.self] }
        set { self[ShowsAdvancedKey.self] = newValue }
    }
}

// MARK: - Badges

enum SBadgeKind {
    /// The value differs from the default ("Customized").
    case custom
    /// The setting only works with one engine ("Parakeet", "Whisper").
    case engine
    /// Something recently added.
    case new
    /// Shown in the design but not built yet ("Soon"). The row's control is disabled.
    case soon
}

struct SBadge: View {
    let label: LocalizedStringKey
    let kind: SBadgeKind

    init(_ label: LocalizedStringKey, kind: SBadgeKind) {
        self.label = label
        self.kind = kind
    }

    var body: some View {
        Text(label)
            .scaledFont(size: 10.5, weight: .bold)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundColor(foreground)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .custom: return STheme.customText
        case .engine: return STheme.hint
        case .new, .soon: return STheme.accent
        }
    }

    private var background: Color {
        switch kind {
        case .custom: return STheme.customBg
        case .engine: return STheme.fill
        case .new, .soon: return STheme.accentSoft
        }
    }
}

/// The badge every unbuilt feature carries.
struct SoonBadge: View {
    var body: some View { SBadge("Soon", kind: .soon) }
}

// MARK: - Groups and rows

/// A titled card of settings rows. Rows draw their own top hairline; the first one sits under the
/// card's border, so separators only show between rows.
struct SettingsGroup<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    /// A group made only of advanced rows appears with the Advanced switch, not before.
    var advanced = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.showsAdvanced) private var showsAdvanced

    var body: some View {
        if !advanced || showsAdvanced {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    if let subtitle {
                        Text(subtitle)
                            .scaledFont(size: 13)
                            .foregroundColor(STheme.hint)
                    }
                    Spacer(minLength: 0)
                    accessory()
                }
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .background(STheme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(STheme.border, lineWidth: 1))
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, advanced: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.advanced = advanced
        self.accessory = { EmptyView() }
        self.content = content
    }
}

extension SettingsGroup {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, advanced: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.advanced = advanced
        self.accessory = accessory
        self.content = content
    }
}

/// The top hairline every row inside a `SettingsGroup` draws.
private struct RowSeparator: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Rectangle().fill(STheme.border).frame(height: 1)
        }
    }
}

/// One setting: label and a sentence of help on the left, its control on the right (or below,
/// for text areas and lists).
///
/// `title` is a catalog key rather than a `LocalizedStringKey` so the settings search can match
/// it and scroll to it: the same string is the row's identity.
struct SettingRow<Control: View>: View {
    let title: String
    var hint: LocalizedStringKey? = nil
    var badge: (LocalizedStringKey, SBadgeKind)? = nil
    /// Hidden until the rubric's Advanced switch is on, and tinted when shown.
    var advanced = false
    /// Not built yet: carries the Soon badge and its control is disabled.
    var soon = false
    /// Puts the control under the label, full width.
    var stacked = false
    var indented = false
    @ViewBuilder var control: () -> Control
    @Environment(\.showsAdvanced) private var showsAdvanced

    init(_ title: String, hint: LocalizedStringKey? = nil, badge: (LocalizedStringKey, SBadgeKind)? = nil,
         advanced: Bool = false, soon: Bool = false, stacked: Bool = false, indented: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.hint = hint
        self.badge = badge
        self.advanced = advanced
        self.soon = soon
        self.stacked = stacked
        self.indented = indented
        self.control = control
    }

    var body: some View {
        if !advanced || showsAdvanced {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 10) {
                        label
                        control().disabled(soon)
                    }
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        label
                        Spacer(minLength: 0)
                        control()
                            .disabled(soon)
                            .opacity(soon ? 0.5 : 1)
                    }
                }
            }
            .padding(.leading, indented ? 34 : 16)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(advanced ? STheme.advancedBg : Color.clear)
            .modifier(RowSeparator())
            .id(title)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(soon ? STheme.hint : STheme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
                if soon {
                    SoonBadge()
                } else if let badge {
                    SBadge(badge.0, kind: badge.1)
                }
            }
            if let hint {
                Text(hint)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
    }
}

extension SettingRow where Control == EmptyView {
    init(_ title: String, hint: LocalizedStringKey? = nil, badge: (LocalizedStringKey, SBadgeKind)? = nil,
         advanced: Bool = false, soon: Bool = false) {
        self.init(title, hint: hint, badge: badge, advanced: advanced, soon: soon) { EmptyView() }
    }
}

/// A tinted line inside a group that explains a condition and offers the fix next to it
/// ("Right ⌥ needs Input Monitoring", "Codex questions stay in the terminal").
struct SettingNotice<Action: View>: View {
    let text: LocalizedStringKey
    var advanced = false
    @ViewBuilder var action: () -> Action
    @Environment(\.showsAdvanced) private var showsAdvanced

    init(_ text: LocalizedStringKey, advanced: Bool = false, @ViewBuilder action: @escaping () -> Action) {
        self.text = text
        self.advanced = advanced
        self.action = action
    }

    var body: some View {
        if !advanced || showsAdvanced {
            HStack(spacing: 16) {
                Text(text)
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                action()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(STheme.noticeBg)
            .modifier(RowSeparator())
        }
    }
}

extension SettingNotice where Action == EmptyView {
    init(_ text: LocalizedStringKey, advanced: Bool = false) {
        self.init(text, advanced: advanced) { EmptyView() }
    }
}

// MARK: - Controls

/// The redesign's switch: terracotta when on, warm grey when off. Drawn rather than left to
/// AppKit, which greys an "on" switch out whenever its window is not the key one, so the
/// settings card looked half switched off next to any other window.
struct SSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(SSwitchStyle())
            .labelsHidden()
    }
}

struct SSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        let width: CGFloat = small ? 32 : 40
        let height: CGFloat = small ? 19 : 24
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? STheme.accent : STheme.track)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}

enum SButtonKind {
    /// Bordered cream button, the default.
    case secondary
    /// Terracotta fill: the one action a screen is about.
    case primary
    /// Green, for a state that is already good ("✓ Active", "✓ Connected").
    case ok
    /// Terracotta text on cream: removing or resetting something.
    case danger
    /// Borderless beige fill.
    case quiet
}

struct SButtonStyle: ButtonStyle {
    var kind: SButtonKind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(size: 13, weight: .semibold)
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: kind == .quiet || kind == .primary ? 0 : 1))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .secondary, .quiet: return STheme.textBright
        case .primary: return STheme.onAccent
        case .ok: return STheme.ok
        case .danger: return STheme.accent
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .secondary, .danger: return pressed ? STheme.fill : STheme.controlBg
        case .primary: return pressed ? STheme.accentPressed : STheme.accent
        case .ok: return STheme.okBg
        case .quiet: return pressed ? STheme.border : STheme.fill
        }
    }

    private var borderColor: Color {
        kind == .ok ? STheme.okBorder : STheme.border
    }
}

extension ButtonStyle where Self == SButtonStyle {
    static var sSecondary: SButtonStyle { SButtonStyle(kind: .secondary) }
    static var sPrimary: SButtonStyle { SButtonStyle(kind: .primary) }
    static var sOK: SButtonStyle { SButtonStyle(kind: .ok) }
    static var sDanger: SButtonStyle { SButtonStyle(kind: .danger) }
    static var sQuiet: SButtonStyle { SButtonStyle(kind: .quiet) }
}

/// A pop-up menu drawn as the redesign's bordered "Value ▾" button. The content is any menu
/// content: a `Picker` gives check marks, plain `Button`s give actions.
struct SMenu<Content: View>: View {
    let label: Text
    @ViewBuilder var content: () -> Content

    init(_ label: Text, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                label
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundColor(STheme.hint)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        // The button style draws the label as given. A borderless menu flattens it to a plain
        // title and icon, losing the border, the type size and the chevron's place.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Picks one value from a list, shown as an `SMenu` with a check mark on the current value.
struct SPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: LocalizedStringKey)]

    var body: some View {
        SMenu(Text(currentLabel)) {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var currentLabel: LocalizedStringKey {
        options.first { $0.value == selection }?.label ?? ""
    }
}

/// The redesign's segmented control: a beige track with the chosen segment raised in cream.
struct SSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: LocalizedStringKey)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .scaledFont(size: 13, weight: selected ? .semibold : .medium)
                        .foregroundColor(selected ? STheme.textBright : STheme.hint)
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? STheme.cardBg : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1.5, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.fill))
        .fixedSize()
    }
}

/// A slider with its current value written beside it.
struct SSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let valueLabel: String

    var body: some View {
        HStack(spacing: 12) {
            // Stepped by rounding rather than through `Slider(step:)`, which on macOS draws a
            // tick under the track for every step.
            Slider(value: Binding(
                get: { value },
                set: { newValue in
                    guard let step, step > 0 else { value = newValue; return }
                    let snapped = (newValue / step).rounded() * step
                    value = min(max(snapped, range.lowerBound), range.upperBound)
                }), in: range)
            .tint(STheme.accent)
            .frame(width: 180)
            Text(valueLabel)
                .scaledFont(size: 13, weight: .medium)
                .monospacedDigit()
                .foregroundColor(STheme.textSecondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

/// A single-line text field in the redesign's bordered style.
struct STextField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var monospaced = false
    var width: CGFloat? = 260

    init(_ prompt: LocalizedStringKey, text: Binding<String>, monospaced: Bool = false, width: CGFloat? = 260) {
        self.prompt = prompt
        self._text = text
        self.monospaced = monospaced
        self.width = width
    }

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, design: monospaced ? .monospaced : .default)
            .foregroundColor(STheme.textBright)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
    }
}

/// A key or key combination, drawn as a raised cap ("⌥ right", "Esc").
struct SKeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.textBright)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .fixedSize()
    }
}

// MARK: - Pages

/// Title block of a main page (Home, Dictionary, Snippets, Style).
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .scaledFont(size: 30, weight: .bold)
                    .foregroundColor(STheme.textBright)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 16)
                        .foregroundColor(STheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

extension PageHeader {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }
}

/// A pill-shaped filter chip ("All", "Dictations", "Errors · 1"). Selected is filled dark.
struct SFilterChip: View {
    let label: Text
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .scaledFont(size: 13, weight: selected ? .semibold : .regular)
                .foregroundColor(selected ? STheme.windowBg : STheme.textBright)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(selected ? STheme.textBright : Color.clear))
                .overlay(Capsule().stroke(selected ? Color.clear : STheme.border, lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// A modal card centred over the window, on a dimmed backdrop. Esc and a click on the backdrop
/// close it. Used by the settings, Help & what's new, and the dictionary entry editor.
struct ModalCard<Content: View>: View {
    var maxWidth: CGFloat = 1040
    var maxHeight: CGFloat = 720
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            STheme.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            content()
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .background(STheme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(STheme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 16)
                .padding(28)
        }
        .onExitCommand(perform: onClose)
    }
}

/// The round ✕ that closes a modal card.
struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

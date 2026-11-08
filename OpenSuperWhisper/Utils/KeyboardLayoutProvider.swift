import Carbon
import AppKit
import os

struct KeyboardLayoutInfo {
    let labels: [UInt16: String]
    let physicalType: PhysicalKeyboardType
    
    enum PhysicalKeyboardType {
        case ansi
        case iso
        case jis
    }
}

final class KeyboardLayoutProvider {
    
    static let shared = KeyboardLayoutProvider()
    private init() {}
    
    static let ansiKeycodes: [UInt16] = [
        50,                                         // row0: ` ~
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,   // row0: 1-0
        27, 24,                                     // row0: - =
        12, 13, 14, 15, 17, 16, 32, 34, 31, 35,   // row1: Q-P
        33, 30,                                     // row1: [ ]
        42,                                         // row1: backslash
        0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39,     // row2: A-'
        6, 7, 8, 9, 11, 45, 46, 43, 47, 44,       // row3: Z-/
    ]
    
    func detectPhysicalType() -> KeyboardLayoutInfo.PhysicalKeyboardType {
        let kbType = Int16(LMGetKbdType())
        let layoutType = KBGetLayoutType(kbType)
        if layoutType == UInt32(kKeyboardISO) {
            return .iso
        } else if layoutType == UInt32(kKeyboardJIS) {
            return .jis
        } else {
            return .ansi
        }
    }
    
    func resolveLabels() -> [UInt16: String]? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let kbType = UInt32(LMGetKbdType())
        var result: [UInt16: String] = [:]
        
        for keycode in Self.ansiKeycodes {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                kbType,
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let char = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
                result[keycode] = char.uppercased()
            }
        }
        
        return result
    }
    
    func resolveInfo() -> KeyboardLayoutInfo? {
        let physicalType = detectPhysicalType()
        guard physicalType == .ansi else { return nil }
        guard let labels = resolveLabels() else { return nil }
        guard labels.count == Self.ansiKeycodes.count else { return nil }
        return KeyboardLayoutInfo(labels: labels, physicalType: physicalType)
    }
    
    func labelForKeycode(_ keycode: UInt16, in info: KeyboardLayoutInfo) -> String {
        info.labels[keycode] ?? ""
    }
    
    /// The languages the active input source declares, in the order it declares them, the first
    /// being its primary. Empty for a layout that declares none.
    ///
    /// Only the main thread reads the input source: HIToolbox asserts it is on the main queue and
    /// traps anywhere else, which is how 0.15.0 crashed when the AI cleanup resolved its backend,
    /// and so the dictation language, from a background task. Off the main thread this answers
    /// with the last main-thread read, which the recording's own read at its start keeps current:
    /// the layout the user spoke in, not the one they switched to since.
    static func inputSourceLanguages() -> [String] {
        guard Thread.isMainThread else { return lastLanguagesRead.withLock { $0 } }
        let languages = readInputSourceLanguages()
        lastLanguagesRead.withLock { $0 = languages }
        return languages
    }

    private static let lastLanguagesRead = OSAllocatedUnfairLock<[String]>(initialState: [])

    private static func readInputSourceLanguages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        return Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
    }

    static func inputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
}

// MARK: - The key that pastes

extension KeyboardLayoutProvider {

    /// Where V sits on a US board (kVK_ANSI_V). Also the answer whenever the layout cannot be
    /// read or has no key for "v", which is the behavior every layout had before this lookup.
    static let qwertyPasteKeyCode: CGKeyCode = 0x09

    /// The key code to post with ⌘ for a paste in the layout described by `layoutData`.
    ///
    /// Apps match ⌘V by the character the key produces in the active layout, not by its position,
    /// so a fixed 0x09 is K on Dvorak and opens Notes' link sheet instead of pasting (#161).
    static func pasteKeyCode(layoutData: CFData?, keyboardType: UInt32) -> CGKeyCode {
        guard let layoutData,
              let keyCode = commandKeyCode(producing: "v", layoutData: layoutData,
                                           keyboardType: keyboardType)
        else { return qwertyPasteKeyCode }
        return keyCode
    }

    /// The key that types `character` while only ⌘ is held, or nil when no key does.
    ///
    /// Translated with ⌘ down rather than bare, because that is what the shortcut sees: the
    /// "Dvorak - QWERTY ⌘" layouts go back to QWERTY positions while ⌘ is held, and the
    /// non-Latin layouts (Russian, Greek, Hebrew, …) produce Latin letters there. Only the
    /// unshifted state is searched: a key that needs Shift for the letter would turn the paste
    /// into ⌘⇧V, which is Paste and Match Style. 0x09 wins a tie, so a layout that already
    /// worked keeps the exact key it had.
    static func commandKeyCode(producing character: Character, layoutData: CFData,
                               keyboardType: UInt32) -> CGKeyCode? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let commandOnly = UInt32((cmdKey >> 8) & 0xFF)
        let target = String(character)

        func produces(_ keyCode: CGKeyCode) -> Bool {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), commandOnly,
                                        keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, chars.count, &length, &chars)
            return status == noErr && String(utf16CodeUnits: chars, count: length) == target
        }

        if produces(qwertyPasteKeyCode) { return qwertyPasteKeyCode }
        return (0..<128).map(CGKeyCode.init).first(where: produces)
    }

    /// The Unicode layout data of the layout typing would use right now. An input method
    /// (Japanese, Chinese, …) reports the Latin layout it types with.
    static func currentLayoutData() -> CFData? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
    }

    /// The paste key for the current layout, resolved once per input source change.
    func pasteKeyCode() -> CGKeyCode {
        PasteKeyCodeCache.shared.keyCode
    }
}

/// Holds the resolved paste key until the selected input source changes.
final class PasteKeyCodeCache: NSObject {

    static let shared = PasteKeyCodeCache()

    private let center: DistributedNotificationCenter
    private let resolve: () -> CGKeyCode
    private let lock = NSLock()
    private var cached: CGKeyCode?

    init(center: DistributedNotificationCenter = .default(),
         changeNotification: Notification.Name =
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
         resolve: @escaping () -> CGKeyCode = {
            KeyboardLayoutProvider.pasteKeyCode(layoutData: KeyboardLayoutProvider.currentLayoutData(),
                                                keyboardType: UInt32(LMGetKbdType()))
         }) {
        self.center = center
        self.resolve = resolve
        super.init()
        // Delivered immediately, because the app is almost never active when it pastes: the
        // default behavior holds distributed notifications back while the app is in the
        // background, and the cache would still hold the previous layout's key at paste time.
        center.addObserver(self, selector: #selector(inputSourceChanged),
                           name: changeNotification, object: nil,
                           suspensionBehavior: .deliverImmediately)
    }

    deinit {
        center.removeObserver(self)
    }

    var keyCode: CGKeyCode {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = resolve()
        cached = resolved
        return resolved
    }

    @objc private func inputSourceChanged() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

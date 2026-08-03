import Cocoa
import Carbon

enum ClipboardUtil {
    /// Copies text to the clipboard. Used only as an optional independent stash;
    /// insertion into the focused app is done by `TextInserter`, not the clipboard.
    static func copyToClipboard(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Borrow-and-restore (paste mode with "Copy to clipboard" off — #44)

    /// The pasteboard's full contents (every item, every type), so it can be put back
    /// after the clipboard is borrowed as the ⌘V paste vehicle.
    struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    static func snapshot(of pasteboard: NSPasteboard = .general) -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { acc, type in
                acc[type] = item.data(forType: type)
            }
        }
        return Snapshot(items: items)
    }

    /// Writes a snapshot back, replacing the pasteboard's current contents.
    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { typeMap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typeMap { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// How long the borrowed pasteboard keeps the transcription before the previous contents come
    /// back: long enough for the frontmost app to service the synthetic ⌘V even under post-
    /// transcription CPU load (the pre-0.9.0 restore logic topped out at 0.5s under load — this
    /// adds margin, and being generous costs nothing now that the wait no longer blocks a thread).
    static let borrowRestoreDelay: TimeInterval = 1.0

    /// Borrows whose restore hasn't fired yet, keyed by pasteboard name. A borrow that lands while
    /// another is still pending must NOT snapshot — the pasteboard currently holds the previous
    /// borrow's transcription, and restoring that later would overwrite the user's contents with
    /// dictated text, the very thing "Copy to clipboard" off exists to prevent. Instead it inherits
    /// the pending borrow's snapshot and cancels its timer, so any number of overlapping borrows
    /// collapse into a single restore of the original contents. Main-thread only, like every
    /// caller (the restore timers are on the main queue too, so there is no interleaving).
    private static var pendingBorrows: [NSPasteboard.Name: (saved: Snapshot, restore: DispatchWorkItem)] = [:]

    /// Puts `text` on the pasteboard just long enough for `paste` (a synthetic ⌘V) to be serviced,
    /// then restores the previous contents — for when the user opted out of keeping transcriptions
    /// on the clipboard and it's only borrowed as the paste vehicle (#44). The restore is skipped
    /// if anything else writes to the pasteboard within the delay (a user copy, a clipboard
    /// manager): newer content wins over our restore. Overlapping borrows — a dictation insert
    /// followed within the delay by the paste-last shortcut — coalesce onto the first borrow's
    /// snapshot, so the user's clipboard comes back no matter how many borrows stacked up.
    static func borrowForPaste(_ text: String,
                               on pasteboard: NSPasteboard = .general,
                               restoreAfter delay: TimeInterval = borrowRestoreDelay,
                               paste: () -> Void) {
        let saved: Snapshot
        if let pending = pendingBorrows[pasteboard.name] {
            pending.restore.cancel()
            saved = pending.saved
        } else {
            saved = snapshot(of: pasteboard)
        }
        copyToClipboard(text, to: pasteboard)
        let borrowChangeCount = pasteboard.changeCount
        paste()
        let restoreItem = DispatchWorkItem {
            pendingBorrows[pasteboard.name] = nil
            guard pasteboard.changeCount == borrowChangeCount else { return }
            restore(saved, to: pasteboard)
        }
        pendingBorrows[pasteboard.name] = (saved, restoreItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: restoreItem)
    }

    // MARK: - Input source helpers (used by keyboard-layout tests)

    static func getCurrentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }

    static func switchToInputSource(withID targetID: String) -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }

        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String

            if sourceID.contains(targetID) || targetID.contains(sourceID) || sourceID == targetID {
                let result = TISSelectInputSource(source)
                usleep(100000) // 100ms delay for layout switch
                return result == noErr
            }
        }
        return false
    }

    static func getAvailableInputSources() -> [String] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }

        var result: [String] = []
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let selectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { continue }

            let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self) == kCFBooleanTrue
            if isSelectable {
                let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                result.append(sourceID)
            }
        }
        return result
    }
}

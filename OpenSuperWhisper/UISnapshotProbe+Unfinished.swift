#if DEBUG
import Foundation

@MainActor
extension UISnapshotProbe {
    /// Two takes a crash left behind, written for real into the isolated `unfinished/` folder and
    /// listed by the same scan the app runs at launch.
    static func seedUnfinished(recovered: Bool = false) {
        let directory = UnfinishedDictations.directory
        // Every render of a run shares one storage folder; start from the two takes only.
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        let takes = [(now - 90_000, 72), (now - 3_600, 9)]
        for (started, seconds) in takes {
            let name = "rec-\(started)-\(String(started, radix: 16).prefix(8)).wav"
            try? WAVHeaderRepair.syntheticWAV(seconds: seconds, staleSizes: true)
                .write(to: directory.appendingPathComponent(name))
        }
        let model = UnfinishedDictations.shared
        model.refresh()
        if recovered {
            model.seedForSnapshot(clips: Array(model.clips.dropFirst()), recovered: [
                "Remind me to send the revised quote to Hélène before Thursday, and ask her whether the delivery date still works.",
            ])
        }
    }
}
#endif

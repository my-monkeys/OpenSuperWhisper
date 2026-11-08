import Foundation

/// The frames and binaries read out of a MetricKit call stack tree.
struct ParsedCallStack: Equatable {
    /// One line per frame: binary, runtime address, and the offset into the binary when known.
    var frames: [String]
    /// One `image <binary> <UUID>` line per distinct binary seen in `frames`.
    var images: [String]
}

/// Reads the JSON `MXCallStackTree.jsonRepresentation()` returns. Pure, so it is testable without a
/// live payload.
///
/// The address alone cannot be symbolicated: ASLR moves it at every launch and the report does not
/// say which binary build it belongs to. The offset into the binary's text segment and the binary's
/// UUID are what `atos` and the dSYM need, so both are kept.
enum CallStackTree {

    static let defaultFrameLimit = 60

    /// The walk gives up past this many frames, so a malformed or absurdly deep tree cannot spin.
    private static let maxWalkedFrames = 2000

    /// The attributed thread's frames, crash site first: the tree's root frame is the one that
    /// faulted and each sub-frame is its caller, so the walk is already in that order and what
    /// `limit` cuts is the thread's entry, never the frame that faulted. The 0.15.0 reports, which
    /// printed the walk as is, show it: libdispatch's trap at #0, the Swift job runner last, and
    /// every app frame a caller of the one above it. Anything unexpected in
    /// the shape yields fewer frames rather than a throw: a report with a short stack still helps
    /// and one that crashes the reporter helps no one.
    static func parse(_ json: Data, limit: Int = defaultFrameLimit) -> ParsedCallStack {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return ParsedCallStack(frames: [], images: [])
        }
        // Apple documents a `callStackTree` wrapper; accept the bare form too.
        let root = top["callStackTree"] as? [String: Any] ?? top
        guard let stacks = root["callStacks"] as? [[String: Any]] else {
            return ParsedCallStack(frames: [], images: [])
        }
        let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard let rootFrames = attributed?["callStackRootFrames"] as? [[String: Any]] else {
            return ParsedCallStack(frames: [], images: [])
        }

        var walked: [(line: String, image: String?)] = []
        func walk(_ frame: [String: Any]) {
            guard walked.count < maxWalkedFrames else { return }
            let binary = frame["binaryName"] as? String ?? "?"
            var line = "\(binary) 0x\(String(unsigned(frame["address"]) ?? 0, radix: 16))"
            if let offset = unsigned(frame["offsetIntoBinaryTextSegment"]) {
                line += " +0x\(String(offset, radix: 16))"
            }
            var image: String?
            if let uuid = frame["binaryUUID"] as? String, !uuid.isEmpty {
                image = "image \(binary) \(uuid)"
            }
            walked.append((line, image))
            for sub in frame["subFrames"] as? [[String: Any]] ?? [] { walk(sub) }
        }
        rootFrames.forEach(walk)

        let kept = walked.prefix(max(0, limit))
        var images: [String] = []
        for case let image? in kept.map(\.image) where !images.contains(image) {
            images.append(image)
        }
        return ParsedCallStack(frames: kept.map(\.line), images: images)
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }
}

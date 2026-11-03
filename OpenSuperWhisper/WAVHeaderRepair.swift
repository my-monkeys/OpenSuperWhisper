import Foundation

/// Repairs the header of a WAV that a crash cut short.
///
/// AVAudioRecorder writes the samples as it goes but only fills in the RIFF and data sizes when
/// the file is closed, so a take interrupted by a crash or a force-quit has the right audio and
/// sizes that say it is empty. Players and decoders trust the sizes, so the audio is unreadable
/// until they are rewritten from the length the file really has.
enum WAVHeaderRepair {
    struct Repaired: Equatable {
        let header: Data
        let audioBytes: UInt64
        let duration: TimeInterval
    }

    /// Enough for every header AVAudioRecorder writes, including its alignment filler chunk.
    static let headerWindow = 4096
    private static let unsetSize: UInt32 = 0xFFFF_FFFF

    /// The header with sizes that match a file of `fileLength` bytes, or nil when the file holds
    /// no audio (no `data` chunk, or nothing after it) and there is nothing to recover.
    /// A data size that is set and fits in the file is trusted, so a clean file, possibly with
    /// metadata after its audio, comes back unchanged.
    static func repair(header: Data, fileLength: UInt64) -> Repaired? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "WAVE" else { return nil }
        var byteRate: UInt32 = 0
        var blockAlign: UInt32 = 1
        var position = 12
        while position + 8 <= bytes.count {
            let id = tag(bytes, position)
            let size = word(bytes, position + 4)
            let body = position + 8
            if id == "fmt ", body + 14 <= bytes.count {
                byteRate = word(bytes, body + 8)
                blockAlign = max(1, UInt32(bytes[body + 12]) | UInt32(bytes[body + 13]) << 8)
            }
            if id == "data" {
                return finish(bytes, dataSizeAt: position + 4, dataStart: UInt64(body), stated: size,
                              fileLength: fileLength, byteRate: byteRate, blockAlign: blockAlign)
            }
            position = body + Int(size) + Int(size & 1)
        }
        return nil
    }

    private static func finish(_ bytes: [UInt8], dataSizeAt: Int, dataStart: UInt64, stated: UInt32,
                               fileLength: UInt64, byteRate: UInt32, blockAlign: UInt32) -> Repaired? {
        guard fileLength > dataStart else { return nil }
        let available = fileLength - dataStart
        let trusted = stated != 0 && stated != unsetSize && UInt64(stated) <= available
        let audio = trusted ? UInt64(stated) : available - available % UInt64(blockAlign)
        guard audio > 0 else { return nil }
        var fixed = bytes
        if !trusted {
            put(&fixed, UInt32(truncatingIfNeeded: audio), at: dataSizeAt)
            put(&fixed, UInt32(truncatingIfNeeded: dataStart + audio - 8), at: 4)
        }
        let duration = byteRate > 0 ? Double(audio) / Double(byteRate) : 0
        return Repaired(header: Data(fixed), audioBytes: audio, duration: duration)
    }

    /// Fixes the file in place and returns its duration, or nil when it holds no audio.
    /// Touches nothing when the header is already right.
    static func repairFile(at url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: headerWindow),
              let repaired = repair(header: head, fileLength: length) else { return nil }
        if repaired.header != head {
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: repaired.header)
        }
        return repaired.duration
    }

    private static func tag(_ bytes: [UInt8], _ at: Int) -> String {
        String(decoding: bytes[at..<at + 4], as: UTF8.self)
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
    }

    private static func put(_ bytes: inout [UInt8], _ value: UInt32, at: Int) {
        for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
    }

#if DEBUG
    /// A 16 kHz mono float WAV of silence, the format the recorder writes. With `staleSizes` it
    /// looks like a take the crash cut: full audio, header sizes of zero.
    static func syntheticWAV(seconds: Int, staleSizes: Bool) -> Data {
        let audio = seconds * 64_000
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append(_ value: UInt32) { (0..<4).forEach { header.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32($0)))) } }
        func append(_ value: UInt16) { (0..<2).forEach { header.append(UInt8(truncatingIfNeeded: value >> (8 * UInt16($0)))) } }
        append("RIFF"); append(staleSizes ? 0 : UInt32(36 + audio)); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(64_000)); append(UInt16(4)); append(UInt16(32))
        append("data"); append(staleSizes ? 0 : UInt32(audio))
        return header + Data(count: audio)
    }
#endif
}

import Foundation

/// Splits audio that is too big for one upload into parts a remote server accepts, and encodes
/// each part as a WAV file. Pure, so the cut points and the bytes can be pinned without a server.
enum RemoteUploadChunks {
    /// OpenAI, Groq and Microsoft cap the uploaded file at 25 MB; the margin covers the
    /// multipart fields around it.
    static let maxFileBytes = 24_000_000

    static let sampleRate = 16_000
    static let wavHeaderBytes = 44

    /// How far before the hard limit a cut may move to find a pause.
    private static let searchSeconds = 30
    private static let windowSamples = sampleRate / 10
    private static let windowStride = windowSamples / 2

    /// Samples a part of at most `maxBytes` holds once encoded as 16-bit mono WAV.
    static func maxSamples(forBytes maxBytes: Int) -> Int {
        max(1, (maxBytes - wavHeaderBytes) / 2)
    }

    /// Contiguous ranges covering every sample once, each at most `maxSamples` long. A part ends
    /// at the centre of the quietest 100 ms window in the last 30 s before its hard limit, so a
    /// cut falls in a pause rather than through a word. The last part takes the remainder.
    static func plan(samples: [Float], maxSamples: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxSamples {
            let limit = start + maxSamples
            let cut = quietestCut(in: samples, start: start, limit: limit)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    private static func quietestCut(in samples: [Float], start: Int, limit: Int) -> Int {
        let searchStart = max(start, limit - searchSeconds * sampleRate)
        let window = min(windowSamples, limit - searchStart)
        var bestCut = limit
        var bestEnergy = Double.infinity
        // `<=` keeps the latest of equally quiet windows, so parts stay as long as they can.
        for windowStart in stride(from: searchStart, through: limit - window, by: windowStride) {
            var energy = 0.0
            for index in windowStart..<(windowStart + window) {
                energy += Double(samples[index]) * Double(samples[index])
            }
            if energy <= bestEnergy {
                bestEnergy = energy
                bestCut = windowStart + window / 2
            }
        }
        return max(bestCut, start + 1)
    }

    /// 16-bit PCM mono WAV at 16 kHz. Samples outside [-1, 1] are clamped.
    static func wavData(samples: ArraySlice<Float>) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: wavHeaderBytes + dataBytes)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))                    // PCM
        data.appendLE(UInt16(1))                    // mono
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * 2))       // byte rate
        data.appendLE(UInt16(2))                    // block align
        data.appendLE(UInt16(16))                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(dataBytes))
        // Built in one buffer: appending sample by sample takes seconds on an hour of audio.
        let pcm = samples.map { Int16(min(1, max(-1, $0)) * Float(Int16.max)).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// `<original basename>-part<N>.wav`, N counted from 1.
    static func partFilename(original: String, index: Int) -> String {
        let base = (original as NSString).deletingPathExtension
        return "\(base)-part\(index + 1).wav"
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

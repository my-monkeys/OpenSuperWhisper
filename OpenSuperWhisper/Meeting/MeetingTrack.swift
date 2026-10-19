import AVFoundation

/// One side of a meeting written to disk as it comes in (#159): whatever format the source
/// delivers is converted to 16 kHz mono, the engines' own rate, and appended to a CAF file. CAF
/// keeps every sample written so far readable even if the app dies an hour in, which an M4A
/// without its index would not.
final class MeetingTrackWriter: @unchecked Sendable {
    static let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: MeetingTranscript.sampleRate,
                                          channels: 1, interleaved: false)!

    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let lock = NSLock()

    init(url: URL) throws {
        // Stored as 16-bit integers, handed in and out as floats: half the size on disk, and
        // nothing a transcription can hear.
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MeetingTranscript.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Converts and appends a buffer. Only its first channel is kept: a microphone's other
    /// channels repeat it, and a call's stereo carries the same voices on both sides.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let mono = Self.firstChannel(of: buffer) else { return }
        if sourceFormat != mono.format {
            sourceFormat = mono.format
            converter = AVAudioConverter(from: mono.format, to: Self.fileFormat)
        }
        guard let converter else { return }
        let ratio = Self.fileFormat.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.fileFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return mono
        }
        if error == nil, output.frameLength > 0 {
            try? file.write(from: output)
        }
    }

    private static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData, buffer.frameLength > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData
        else { return nil }
        mono.frameLength = buffer.frameLength
        if buffer.format.isInterleaved {
            let stride = Int(buffer.format.channelCount)
            for frame in 0..<Int(buffer.frameLength) { target[0][frame] = source[0][frame * stride] }
        } else {
            target[0].update(from: source[0], count: Int(buffer.frameLength))
        }
        return mono
    }
}

/// Reading a finished track back, in pieces, so an hour of audio never sits in memory at once.
enum MeetingTrackReader {
    /// The window levels of a whole track, read a minute at a time.
    static func levels(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        var levels: [Float] = []
        let block = AVAudioFrameCount(MeetingTranscript.sampleRate * 60)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { return [] }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            levels += MeetingTranscript.frameLevels(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        }
        return levels
    }

    /// The samples between two times, as floats.
    static func samples(of url: URL, in range: ClosedRange<TimeInterval>) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(range.lowerBound * rate)
        let count = AVAudioFrameCount(max(0, (range.upperBound - range.lowerBound) * rate))
        guard start < file.length, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)
        else { return [] }
        file.framePosition = start
        try file.read(into: buffer, frameCount: count)
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Writes samples as the 16 kHz float WAV a dictation clip is, for the engine.
    static func writeClip(_ samples: [Float], to url: URL) throws {
        let format = MeetingTrackWriter.fileFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Both tracks added into one, for listening back from the history.
    static func mix(_ first: URL, _ second: URL, to url: URL) throws {
        let a = try AVAudioFile(forReading: first, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = try AVAudioFile(forReading: second, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = MeetingTrackWriter.fileFormat
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = AVAudioFrameCount(format.sampleRate * 30)
        guard let ba = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: block),
              let bb = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: block),
              let sum = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { return }
        while a.framePosition < a.length || b.framePosition < b.length {
            ba.frameLength = 0
            bb.frameLength = 0
            if a.framePosition < a.length { try a.read(into: ba, frameCount: block) }
            if b.framePosition < b.length { try b.read(into: bb, frameCount: block) }
            let frames = max(ba.frameLength, bb.frameLength)
            guard frames > 0, let target = sum.floatChannelData else { break }
            sum.frameLength = frames
            for i in 0..<Int(frames) {
                let x = i < Int(ba.frameLength) ? ba.floatChannelData![0][i] : 0
                let y = i < Int(bb.frameLength) ? bb.floatChannelData![0][i] : 0
                target[0][i] = max(-1, min(1, x + y))
            }
            try out.write(from: sum)
        }
    }
}

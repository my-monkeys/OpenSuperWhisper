import Foundation
import AVFoundation
import CoreAudioTypes
import OpenSuperWhisperCore

/// Reads any audio file into 16 kHz mono float samples, the input every local engine wants.
///
/// Multi-channel input is mixed from the channels that carry signal only. Letting
/// AVAudioConverter downmix instead goes wrong on interfaces that expose several unlabeled
/// inputs with speech on one (an Audient EVO 4 records 2 mics + 2 loopback): the result is
/// silence, and the engine reports "No speech detected".
enum AudioPCMConverter {
    private static func resolveFileURL(_ fileURL: URL) throws -> (URL, Bool) {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count >= 12 else { return (fileURL, false) }

        let ext = fileURL.pathExtension.lowercased()

        let isMP4Header = data[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) // "ftyp"
        if isMP4Header && ext != "m4a" && ext != "mp4" && ext != "m4b" && ext != "aac" {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: fileURL, to: tmpURL)
            return (tmpURL, true)
        }

        return (fileURL, false)
    }

    static func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let (resolvedURL, isTempFile) = try resolveFileURL(fileURL)
            defer {
                if isTempFile { try? FileManager.default.removeItem(at: resolvedURL) }
            }
            let audioFile = try AVAudioFile(forReading: resolvedURL)
            let sourceFormat = audioFile.processingFormat
            let totalFrames = audioFile.length
            
            guard let targetFormat = makeTargetFormat(channelCount: sourceFormat.channelCount) else {
                return nil
            }
            
            let sourceRate = sourceFormat.sampleRate
            let targetRate = targetFormat.sampleRate
            let ratio = targetRate / sourceRate
            
            // Use parallel processing for large files (> 10 seconds of audio)
            // Benchmarked: 4 cores = +339%, 8 cores = +609% improvement
            let minFramesForParallel = AVAudioFramePosition(sourceRate * 10)
            let workerCount = totalFrames > minFramesForParallel ? ProcessInfo.processInfo.activeProcessorCount : 1
            
            if workerCount == 1 {
                // Sequential processing for small files
                return try convertSequential(
                    fileURL: resolvedURL,
                    sourceFormat: sourceFormat,
                    targetFormat: targetFormat,
                    ratio: ratio,
                    totalFrames: totalFrames
                )
            }
            
            // Parallel processing: split file into segments
            let framesPerWorker = totalFrames / AVAudioFramePosition(workerCount)
            let outputFrameCount = Int(Double(totalFrames) * ratio) + 1024
            
            // Pre-allocate result array
            var result = [Float](repeating: 0, count: outputFrameCount)
            let resultLock = NSLock()
            var totalWritten = 0
            var hasError = false
            
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "audio.conversion.parallel", attributes: .concurrent)
            
            for workerIndex in 0..<workerCount {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    
                    guard !hasError else { return }
                    
                    let startFrame = AVAudioFramePosition(workerIndex) * framesPerWorker
                    let endFrame = workerIndex == workerCount - 1 ? totalFrames : startFrame + framesPerWorker
                    let segmentFrames = endFrame - startFrame
                    
                    guard let workerFile = try? AVAudioFile(forReading: resolvedURL) else {
                        hasError = true
                        return
                    }
                    
                    do {
                        workerFile.framePosition = startFrame
                    }
                    
                    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                        hasError = true
                        return
                    }
                    converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
                    
                    let inputChunkSize: AVAudioFrameCount = 262144 // 256K for parallel
                    let outputChunkSize = AVAudioFrameCount(Double(inputChunkSize) * ratio) + 256
                    
                    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputChunkSize),
                          let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
                        hasError = true
                        return
                    }
                    
                    var segmentResult = [Float]()
                    let expectedOutputFrames = Int(Double(segmentFrames) * ratio) + 256
                    segmentResult.reserveCapacity(expectedOutputFrames)
                    
                    var framesRead: AVAudioFramePosition = 0
                    
                    while framesRead < segmentFrames {
                        let framesToRead = min(AVAudioFrameCount(segmentFrames - framesRead), inputChunkSize)
                        inputBuffer.frameLength = 0
                        
                        do {
                            try workerFile.read(into: inputBuffer, frameCount: framesToRead)
                        } catch {
                            break
                        }
                        
                        if inputBuffer.frameLength == 0 { break }
                        framesRead += AVAudioFramePosition(inputBuffer.frameLength)
                        
                        var inputConsumed = false
                        var convError: NSError?
                        
                        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                            if inputConsumed {
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                            inputConsumed = true
                            outStatus.pointee = .haveData
                            return inputBuffer
                        }
                        
                        outputBuffer.frameLength = 0
                        converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
                        
                        appendMixedSamples(from: outputBuffer, to: &segmentResult)
                    }
                    
                    // Calculate output position for this segment
                    let outputStartIndex = Int(Double(startFrame) * ratio)
                    
                    resultLock.lock()
                    let writeEnd = min(outputStartIndex + segmentResult.count, result.count)
                    let writeCount = writeEnd - outputStartIndex
                    if writeCount > 0 && !segmentResult.isEmpty {
                        result.replaceSubrange(outputStartIndex..<writeEnd, with: segmentResult.prefix(writeCount))
                        totalWritten = max(totalWritten, writeEnd)
                    }
                    resultLock.unlock()
                }
            }
            
            group.wait()
            
            if hasError { return nil }
            
            // Trim to actual size
            if totalWritten > 0 && totalWritten < result.count {
                result.removeLast(result.count - totalWritten)
            }
            
            return result.isEmpty ? nil : result
        }.value
    }
    
    private static func convertSequential(
        fileURL: URL,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        ratio: Double,
        totalFrames: AVAudioFramePosition
    ) throws -> [Float]? {
        let audioFile = try AVAudioFile(forReading: fileURL)
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        
        let outputFrameCount = AVAudioFrameCount(Double(totalFrames) * ratio) + 1024
        let inputChunkSize: AVAudioFrameCount = 1048576 // 1M for sequential
        
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputChunkSize) else {
            return nil
        }
        
        var result = [Float]()
        result.reserveCapacity(Int(outputFrameCount))
        
        let outputChunkSize = AVAudioFrameCount(Double(inputChunkSize) * ratio) + 256
        guard let chunkOutputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
            return nil
        }
        
        while audioFile.framePosition < totalFrames {
            inputBuffer.frameLength = 0
            try audioFile.read(into: inputBuffer, frameCount: inputChunkSize)
            
            if inputBuffer.frameLength == 0 { break }
            
            var inputConsumed = false
            var error: NSError?
            
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            chunkOutputBuffer.frameLength = 0
            converter.convert(to: chunkOutputBuffer, error: &error, withInputFrom: inputBlock)
            
            if let error = error {
                print("Conversion error: \(error)")
                break
            }
            
            appendMixedSamples(from: chunkOutputBuffer, to: &result)
        }
        
        return result.isEmpty ? nil : result
    }
    
    private static func appendMixedSamples(from buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else { return }
        
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            let mono = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            output.append(contentsOf: mono)
            return
        }
        
        let activityThreshold: Float = 0.0001
        var activeChannels: [Int] = []
        activeChannels.reserveCapacity(channelCount)
        
        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            var energy: Float = 0
            for sample in channelSamples {
                energy += sample * sample
            }
            let rms = sqrtf(energy / Float(frameCount))
            if rms > activityThreshold {
                activeChannels.append(channel)
            }
        }
        
        if activeChannels.isEmpty {
            activeChannels = Array(0..<channelCount)
        }
        
        let normalization = 1.0 / Float(activeChannels.count)
        output.reserveCapacity(output.count + frameCount)
        
        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in activeChannels {
                mixed += channelData[channel][frame]
            }
            output.append(mixed * normalization)
        }
    }
    
    static func makeTargetFormat(channelCount: AVAudioChannelCount) -> AVAudioFormat? {
        guard channelCount > 0 else { return nil }
        
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else { return nil }
        
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            interleaved: false,
            channelLayout: channelLayout
        )
    }

    /// For engines that only take a file: a temporary 16 kHz mono WAV holding the
    /// active-channel mix of a multi-channel `fileURL`, or nil when the file is already mono.
    /// The caller removes the returned file.
    static func monoFileIfMultiChannel(_ fileURL: URL) async throws -> URL? {
        guard try AVAudioFile(forReading: fileURL).processingFormat.channelCount > 1 else { return nil }
        guard let samples = try await convertAudioToPCM(fileURL: fileURL), !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw TranscriptionError.audioConversionFailed }
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let monoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-mono-\(UUID().uuidString)").appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: monoURL, settings: format.settings)
        try file.write(from: buffer)
        return monoURL
    }
}

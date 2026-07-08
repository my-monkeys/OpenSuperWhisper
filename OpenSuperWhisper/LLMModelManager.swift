//
//  LLMModelManager.swift
//  OpenSuperWhisper
//
//  Manages local GGUF LLM models for the built-in llama.cpp cleanup backend.
//  Mirrors WhisperModelManager: models live in
//  Application Support/<bundleID>/llm-models, downloads reuse the
//  URLSession + delegate pattern with progress callbacks.
//

import Combine
import Foundation

/// Reuses the same URLSession download-delegate shape as WhisperDownloadDelegate.
/// Kept separate so the two managers don't share mutable delegate state.
class LLMDownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private var expectedContentLength: Int64 = 0
    var completionHandler: ((URL?, Error?) -> Void)?
    weak var downloadTask: URLSessionDownloadTask?

    init(progressCallback: @escaping (Double) -> Void) {
        self.progressCallback = progressCallback
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler?(location, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if expectedContentLength == 0 {
            expectedContentLength = totalBytesExpectedToWrite
        }
        let progress = expectedContentLength > 0
            ? Double(totalBytesWritten) / Double(expectedContentLength)
            : 0
        DispatchQueue.main.async { [weak self] in
            self?.progressCallback(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler?(nil, error)
        }
    }
}

/// Descriptor for a downloadable LLM model.
struct LLMModelDescriptor {
    /// Human-readable name shown in UI.
    let displayName: String
    /// On-disk filename (also used as the download "name" key).
    let fileName: String
    /// Hugging Face (or other) download URL.
    let downloadURL: URL
    /// Approximate download size in bytes (for UI display).
    let approxBytes: Int64
}

class LLMModelManager {
    static let shared = LLMModelManager()

    /// Default built-in cleanup model: Qwen2.5-1.5B-Instruct, GGUF Q4_K_M.
    /// Qwen2.5 is licensed Apache-2.0 (https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct/blob/main/LICENSE),
    /// so it is safe to bundle/download for a zero-setup local backend.
    /// Source: official Qwen first-party GGUF repo. Filename casing is exact —
    /// HF is case-sensitive and a wrong case is a silent 404 (verified 2026-06-27:
    /// HTTP 200, 1,117,320,736 bytes).
    static let defaultModel = LLMModelDescriptor(
        displayName: "Qwen2.5 1.5B Instruct (Q4_K_M)",
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true")!,
        approxBytes: 1_117_320_736
    )

    private let modelsDirectoryName = "llm-models"
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let downloadTasksLock = NSLock()

    var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent(modelsDirectoryName)
    }

    private init() {
        createModelsDirectoryIfNeeded()
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create LLM models directory: \(error)")
        }
    }

    /// All downloaded .gguf models on disk.
    func getAvailableModels() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("Failed to get available LLM models: \(error)")
            return []
        }
    }

    /// On-disk location for a model by filename (whether or not it exists yet).
    func localURL(for name: String) -> URL {
        return modelsDirectory.appendingPathComponent(name)
    }

    /// Whether a specific model file is present on disk.
    func isModelDownloaded(name: String) -> Bool {
        return FileManager.default.fileExists(atPath: localURL(for: name).path)
    }

    /// Convenience: is the default Qwen model present?
    func isDefaultModelDownloaded() -> Bool {
        return isModelDownloaded(name: Self.defaultModel.fileName)
    }

    /// Download a model with progress callback, reusing the WhisperModelManager pattern.
    func downloadModel(url: URL, name: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destinationURL = localURL(for: name)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("LLM model already exists at: \(destinationURL.path)")
            DispatchQueue.main.async { progressCallback(1.0) }
            return
        }

        print("Starting LLM model download:")
        print("- URL: \(url.absoluteString)")
        print("- Destination: \(destinationURL.path)")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = LLMDownloadDelegate(progressCallback: progressCallback)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            // LLM GGUFs are ~1 GB+; allow a generous resource timeout.
            configuration.timeoutIntervalForResource = 1800 // 30 minutes

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)

            let downloadTask = session.downloadTask(with: url)
            delegate.downloadTask = downloadTask

            downloadTasksLock.lock()
            activeDownloadTasks[name] = downloadTask
            downloadTasksLock.unlock()

            delegate.completionHandler = { [weak self] location, error in
                self?.downloadTasksLock.lock()
                self?.activeDownloadTasks.removeValue(forKey: name)
                self?.downloadTasksLock.unlock()

                if let error = error as? URLError, error.code == .cancelled {
                    print("LLM download cancelled")
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error = error {
                    print("LLM download failed with error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let location = location else {
                    let error = NSError(domain: "LLMModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL received"])
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    print("LLM download completed. Moving file to destination...")
                    try FileManager.default.moveItem(at: location, to: destinationURL)
                    print("LLM model saved to: \(destinationURL.path)")
                    DispatchQueue.main.async { progressCallback(1.0) }
                    continuation.resume(returning: ())
                } catch {
                    print("Failed to move downloaded LLM file: \(error)")
                    continuation.resume(throwing: error)
                }
            }

            downloadTask.resume()
        }
    }

    /// Convenience to download the bundled default Qwen model.
    func downloadDefaultModel(progressCallback: @escaping (Double) -> Void) async throws {
        try await downloadModel(url: Self.defaultModel.downloadURL,
                                name: Self.defaultModel.fileName,
                                progressCallback: progressCallback)
    }

    func cancelDownload(name: String) {
        downloadTasksLock.lock()
        defer { downloadTasksLock.unlock() }
        if let task = activeDownloadTasks[name] {
            task.cancel()
            activeDownloadTasks.removeValue(forKey: name)
            print("Cancelled LLM download for: \(name)")
        }
    }
}

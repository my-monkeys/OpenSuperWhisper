import Foundation
import os

/// What a host hands the core: its preferences, where files live, the VAD model, its text
/// formatter, where inference may run, and the two main-actor services the transcription queue
/// needs. Every field but `computePolicy` is a provider, so installing a configuration evaluates
/// none of the host's services.
public struct CoreConfiguration: Sendable {
    public var preferences: @Sendable () -> any CorePreferences
    public var storageRoot: @Sendable () -> URL
    public var vadModelPath: @Sendable () -> String?
    public var textFormatter: @Sendable (String) -> String
    public var computePolicy: ComputePolicy
    public var makeSettings: @MainActor @Sendable () -> TranscriptionSettings
    public var confirmEnableHistory: @MainActor @Sendable () async -> Bool

    public init(preferences: @escaping @Sendable () -> any CorePreferences,
                storageRoot: @escaping @Sendable () -> URL,
                vadModelPath: @escaping @Sendable () -> String?,
                textFormatter: @escaping @Sendable (String) -> String = { $0 },
                computePolicy: ComputePolicy = .automatic,
                makeSettings: @escaping @MainActor @Sendable () -> TranscriptionSettings,
                confirmEnableHistory: @escaping @MainActor @Sendable () async -> Bool) {
        self.preferences = preferences
        self.storageRoot = storageRoot
        self.vadModelPath = vadModelPath
        self.textFormatter = textFormatter
        self.computePolicy = computePolicy
        self.makeSettings = makeSettings
        self.confirmEnableHistory = confirmEnableHistory
    }
}

/// One installed configuration behind a lock. A type of its own so its install and read
/// behaviour can be tested on a private instance without touching the process's.
final class ConfigurationSlot: Sendable {
    private let lock = OSAllocatedUnfairLock<CoreConfiguration?>(initialState: nil)

    var configuration: CoreConfiguration? { lock.withLock { $0 } }

    func install(_ configuration: CoreConfiguration) -> Bool {
        lock.withLock { installed in
            guard installed == nil else { return false }
            installed = configuration
            return true
        }
    }

    func replace(with configuration: CoreConfiguration?) -> CoreConfiguration? {
        lock.withLock { installed in
            let previous = installed
            installed = configuration
            return previous
        }
    }
}

extension CoreConfiguration {
    static let slot = ConfigurationSlot()

    public static var isInstalled: Bool { slot.configuration != nil }

    public static func install(_ configuration: CoreConfiguration) {
        guard slot.install(configuration) else {
            fatalError("CoreConfiguration.install(_:) ran twice. Install it once, on the first line of main.")
        }
    }

    /// Copies the configuration out of the slot. Callers invoke its providers afterwards, never
    /// under the lock: some end in `AppPreferences.init`, which runs migrations.
    static var current: CoreConfiguration {
        guard let configuration = slot.configuration else { fatalError(notInstalledMessage) }
        return configuration
    }

    public static let notInstalledMessage = """
        OpenSuperWhisperCore was used before CoreConfiguration.install(_:). The macOS app installs it \
        on the first line of AppMain.main (AppCore.install()); a SwiftUI preview calls AppCore.install() \
        in its body; core tests call CoreConfiguration.replaceForTesting(_:) or use the designated initialisers.
        """

    #if DEBUG
    /// Core test target only (slice 5). Never call it from the hosted suite: the singletons have
    /// already captured the installed configuration (storage roots, `WhisperEngine.vadModelPath`,
    /// `BuiltInLlamaBackend.shared`'s compute policy), so a replacement would leave one process
    /// running two configurations. Returns the configuration it replaced.
    @discardableResult
    static func replaceForTesting(_ configuration: CoreConfiguration?) -> CoreConfiguration? {
        slot.replace(with: configuration)
    }
    #endif
}

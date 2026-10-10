import Foundation

@testable import OpenSuperWhisper

/// Gives one test an empty preferences store and puts the previous contents back afterwards.
///
/// Every `@UserDefault` in `AppPreferences` reads `DefaultsStore.current`, which under XCTest is
/// already a suite private to this process. Emptying that suite is what a fresh install looks
/// like, and it is the only store the property wrappers can be pointed at without adding an
/// indirection to every preference read in the shipped app. The Keychain accounts a test names
/// are saved and restored the same way, on the test service.
///
/// Unlike the defaults suite, the test Keychain service is one per bundle, shared by the test
/// processes the scheme runs in parallel. Naming accounts therefore also takes a lock across
/// processes until `restore()`, or two tests writing the same account would read each other's
/// value.
final class ScratchPreferences {

    private let suiteName = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
    private let savedDomain: [String: Any]?
    private let savedSecrets: [String: String?]
    private let keychainLock: KeychainLock?

    init(keychainAccounts: [String] = []) {
        keychainLock = keychainAccounts.isEmpty ? nil : KeychainLock()
        savedDomain = DefaultsStore.current.persistentDomain(forName: suiteName)
        savedSecrets = Dictionary(uniqueKeysWithValues: keychainAccounts.map { ($0, Keychain.read($0)) })
        wipe()
        keychainAccounts.forEach { Keychain.set(nil, for: $0) }
    }

    /// Only the keys written since the wipe: the suite's own domain, without the global and
    /// registration domains `dictionaryRepresentation()` folds in.
    var writtenKeys: [String] {
        (DefaultsStore.current.persistentDomain(forName: suiteName) ?? [:]).keys.sorted()
    }

    func wipe() {
        DefaultsStore.current.removePersistentDomain(forName: suiteName)
    }

    func restore() {
        wipe()
        if let savedDomain {
            DefaultsStore.current.setPersistentDomain(savedDomain, forName: suiteName)
        }
        for (account, value) in savedSecrets {
            Keychain.set(value, for: account)
        }
        keychainLock?.release()
    }
}

/// An exclusive `flock` on a file every test process of this app can see. The kernel drops it
/// if the process dies, so a crashed test cannot wedge the others.
///
/// Re-entrant within a process: a `flock` belongs to the open file description, so a second
/// scratch opening the file again while the first still holds it would wait on itself forever.
/// The first holder takes the lock, nested ones only count, and the last release drops it.
final class KeychainLock {
    private static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(AppIdentity.bundleID)-tests-keychain.lock").path

    private static let guardLock = NSLock()
    private static var depth = 0
    private static var descriptor: Int32 = -1

    private var held = true

    init() {
        Self.guardLock.lock(); defer { Self.guardLock.unlock() }
        if Self.depth == 0 {
            Self.descriptor = open(Self.path, O_CREAT | O_RDWR, 0o600)
            precondition(Self.descriptor >= 0, "cannot open \(Self.path)")
            flock(Self.descriptor, LOCK_EX)
        }
        Self.depth += 1
    }

    func release() {
        Self.guardLock.lock(); defer { Self.guardLock.unlock() }
        guard held else { return }
        held = false
        Self.depth -= 1
        guard Self.depth == 0 else { return }
        flock(Self.descriptor, LOCK_UN)
        close(Self.descriptor)
        Self.descriptor = -1
    }

    deinit { release() }
}

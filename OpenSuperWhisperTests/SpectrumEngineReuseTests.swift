import CoreAudio
import XCTest

@testable import OpenSuperWhisper

/// The visualiser keeps one engine from take to take. It must give it up as soon as the take's
/// mic is no longer the one it was built on, or the bubble goes flat (0.12.x), and it must not
/// release an engine whose device is still running, or the app crashes inside CoreAudio
/// (0.15.2 to 0.15.5).
final class SpectrumEngineReuseTests: XCTestCase {
    private let builtFor = SpectrumDefaultDevices(input: 98, output: 74)

    private func reason(now: SpectrumDefaultDevices, behindInput: [AudioDeviceID] = [98, 74],
                        configurationChanged: Bool = false) -> String? {
        SpectrumEngineReuse.rebuildReason(builtFor: builtFor, now: now,
                                          devicesBehindInput: behindInput,
                                          configurationChanged: configurationChanged)
    }

    func testTheSameDevicesKeepTheEngine() {
        XCTAssertNil(reason(now: builtFor))
        XCTAssertNil(reason(now: builtFor, behindInput: [98]), "input and output on one device")
    }

    /// The 0.12.x flat bubble: the recorder switched to another mic and the engine stayed.
    func testAnotherMicReplacesTheEngine() {
        XCTAssertNotNil(reason(now: SpectrumDefaultDevices(input: 120, output: 74)))
    }

    /// The private aggregate is made of the default input and output, so a new output changes it.
    func testAnotherOutputReplacesTheEngine() {
        XCTAssertNotNil(reason(now: SpectrumDefaultDevices(input: 98, output: 155)))
    }

    /// Same defaults, but the unit no longer reads the default input: its device or aggregate
    /// went away underneath it, as after a coreaudiod restart.
    func testAnInputThatLeftTheDefaultReplacesTheEngine() {
        XCTAssertNotNil(reason(now: builtFor, behindInput: [155]))
        XCTAssertNotNil(reason(now: builtFor, behindInput: []))
    }

    /// AVAudioEngine stops itself on a configuration change and is not to be restarted.
    func testAConfigurationChangeReplacesTheEngine() {
        XCTAssertNotNil(reason(now: builtFor, configurationChanged: true))
    }

    // MARK: Deferred release

    private final class Engine {}

    private func entry(_ item: Engine, device: AudioDeviceID) -> DeferredReleases<Engine>.Entry {
        .init(item: item, device: device, retiredAt: 0, listener: nil)
    }

    func testAnEngineWhoseDeviceRunsIsHeldUntilTheDeviceStops() {
        var releases = DeferredReleases<Engine>()
        weak var released: Engine?
        do {
            let engine = Engine()
            released = engine
            releases.add(entry(engine, device: 98))
        }

        XCTAssertTrue(releases.takeStopped(isRunning: { _ in true }).isEmpty)
        XCTAssertNotNil(released, "still running: releasing it now is the crash")
        XCTAssertEqual(releases.entries.count, 1)

        XCTAssertEqual(releases.takeStopped(isRunning: { _ in false }).count, 1)
        XCTAssertNil(released, "stopped: nothing holds it any more")
        XCTAssertTrue(releases.entries.isEmpty)
    }

    func testOnlyEnginesOnStoppedDevicesAreReleasedAndEachDeviceIsReadOnce() {
        var releases = DeferredReleases<Engine>()
        let running = Engine(), stoppedA = Engine(), stoppedB = Engine()
        releases.add(entry(running, device: 98))
        releases.add(entry(stoppedA, device: 155))
        releases.add(entry(stoppedB, device: 155))
        var reads: [AudioDeviceID] = []

        let taken = releases.takeStopped(isRunning: { device in
            reads.append(device)
            return device == 98
        })

        XCTAssertEqual(taken.map { ObjectIdentifier($0.item) },
                       [ObjectIdentifier(stoppedA), ObjectIdentifier(stoppedB)])
        XCTAssertEqual(releases.entries.map { ObjectIdentifier($0.item) }, [ObjectIdentifier(running)])
        XCTAssertEqual(reads.sorted(), [98, 155])
    }

    /// A device that cannot answer is gone, so nothing runs on it and its engine may go.
    func testAMissingDeviceCountsAsStopped() {
        XCTAssertFalse(SpectrumEngineHost.ioIsRunning(on: AudioDeviceID(kAudioObjectUnknown)))
    }
}

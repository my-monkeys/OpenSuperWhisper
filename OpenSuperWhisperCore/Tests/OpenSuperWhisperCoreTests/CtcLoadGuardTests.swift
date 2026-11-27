import XCTest
@testable import OpenSuperWhisperCore

/// The ladder that keeps a CoreML segfault in the CTC encoder compile from recurring on every
/// dictation: a load still recorded as in flight at the next load crashed, so the next one steps
/// down a level, per OS build.
final class CtcLoadGuardTests: CoreTestCase {
    private let build = "Version 27.2.1 (Build 26C101)"

    func testAFreshStateLoadsOnTheNeuralEngineAndRecordsIt() {
        let state = CtcLoadGuardState.beforeLoad(nil, osBuild: build)

        XCTAssertEqual(state, CtcLoadGuardState(osBuild: build, level: .neuralEngine, inFlight: .neuralEngine))
        XCTAssertEqual(state.level.computeUnits, .cpuAndNeuralEngine)
        XCTAssertNil(CtcLoadGuardState.crashedLevel(in: nil, osBuild: build))
    }

    func testACrashAtEachLevelStepsDownOne() {
        let ladder: [(crashed: CtcComputeLevel, next: CtcComputeLevel)] = [
            (.neuralEngine, .gpu), (.gpu, .cpu), (.cpu, .unavailable),
        ]
        for (crashed, next) in ladder {
            let stored = CtcLoadGuardState(osBuild: build, level: crashed, inFlight: crashed)

            let state = CtcLoadGuardState.beforeLoad(stored, osBuild: build)

            XCTAssertEqual(state.level, next, "after a crash at \(crashed)")
            XCTAssertEqual(CtcLoadGuardState.crashedLevel(in: stored, osBuild: build), crashed)
        }
    }

    func testTheGpuAndCpuLevelsCompileWithoutTheNeuralEngine() {
        XCTAssertEqual(CtcComputeLevel.gpu.computeUnits, .cpuAndGPU)
        XCTAssertEqual(CtcComputeLevel.cpu.computeUnits, .cpuOnly)
    }

    func testUnavailableLoadsNothingAndRecordsNoLoad() {
        let crashedOnCpu = CtcLoadGuardState(osBuild: build, level: .cpu, inFlight: .cpu)
        let unavailable = CtcLoadGuardState.beforeLoad(crashedOnCpu, osBuild: build)

        XCTAssertNil(unavailable.level.computeUnits)
        XCTAssertNil(unavailable.inFlight)
        XCTAssertEqual(CtcLoadGuardState.beforeLoad(unavailable, osBuild: build), unavailable,
                       "unavailable stays so for the OS build")
    }

    func testASettledLevelIsKeptWhenTheLastLoadReturned() {
        let settled = CtcLoadGuardState(osBuild: build, level: .gpu)

        let state = CtcLoadGuardState.beforeLoad(settled, osBuild: build)

        XCTAssertEqual(state, CtcLoadGuardState(osBuild: build, level: .gpu, inFlight: .gpu))
    }

    func testAnOsBuildChangeStartsAgainAtTheNeuralEngine() {
        let newBuild = "Version 27.3 (Build 26D50)"
        for stored in [
            CtcLoadGuardState(osBuild: build, level: .unavailable),
            CtcLoadGuardState(osBuild: build, level: .gpu, inFlight: .gpu),
        ] {
            let state = CtcLoadGuardState.beforeLoad(stored, osBuild: newBuild)

            XCTAssertEqual(state, CtcLoadGuardState(osBuild: newBuild, level: .neuralEngine, inFlight: .neuralEngine))
            XCTAssertNil(CtcLoadGuardState.crashedLevel(in: stored, osBuild: newBuild),
                         "a load in flight on another build is not this build's crash")
        }
    }

    /// `afterLoad` runs whether the load returned models or threw: a throw is not a crash, so the
    /// next load starts at the same level.
    func testAReturnedLoadClearsTheRecordWithoutSteppingDown() {
        let loading = CtcLoadGuardState.beforeLoad(nil, osBuild: build)

        let returned = loading.afterLoad()

        XCTAssertEqual(returned, CtcLoadGuardState(osBuild: build, level: .neuralEngine))
        XCTAssertEqual(CtcLoadGuardState.beforeLoad(returned, osBuild: build).level, .neuralEngine)
    }

    func testTheFileRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CtcLoadGuardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(CtcLoadGuardFile.fileName)
        XCTAssertNil(CtcLoadGuardFile.read(url), "no file yet")

        let state = CtcLoadGuardState(osBuild: build, level: .gpu, inFlight: .gpu)
        try CtcLoadGuardFile.write(state, to: url)
        XCTAssertEqual(CtcLoadGuardFile.read(url), state)

        try CtcLoadGuardFile.write(state.afterLoad(), to: url)
        XCTAssertEqual(CtcLoadGuardFile.read(url), state.afterLoad())
    }

    func testAnUnreadableFileStartsAfresh() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CtcLoadGuardTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        XCTAssertNil(CtcLoadGuardFile.read(url))
    }
}

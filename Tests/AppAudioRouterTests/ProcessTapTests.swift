import XCTest
import CoreAudio
@testable import AppAudioRouterCore

final class ProcessTapTests: XCTestCase {
    func testProcessListEnumeration() {
        let manager = AudioProcessManager.shared
        let processes = manager.refreshProcesses()

        // On macOS with CoreAudio running, there are usually client processes connected
        XCTAssertFalse(processes.isEmpty, "CoreAudio should report at least one audio process object")
        
        let first = processes[0]
        XCTAssertGreaterThan(first.pid, 0)
        XCTAssertFalse(first.name.isEmpty)
    }

    func testAggregateDeviceCreationAndDestruction() {
        let manager = AggregateDeviceManager.shared
        let devices = AudioDeviceManager.shared.getOutputDevices()
        guard devices.count >= 1 else { return }

        let uids = [devices[0].uid]
        let aggID = manager.createMultiOutputDevice(
            name: "Test Aggregate Unit",
            subDeviceUIDs: uids,
            isPrivate: true
        )

        XCTAssertNotNil(aggID)
        if let id = aggID {
            manager.destroyDevice(id: id)
        }
    }
}

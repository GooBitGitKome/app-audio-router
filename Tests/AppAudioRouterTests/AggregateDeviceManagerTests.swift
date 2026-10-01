import XCTest
import CoreAudio
@testable import AppAudioRouterCore

final class AggregateDeviceManagerTests: XCTestCase {
    func testCreateAggregateInputDevice() {
        let manager = AggregateDeviceManager.shared
        let inputDevices = AudioDeviceManager.shared.getInputDevices().filter { !$0.isAggregate && $0.inputChannelCount > 0 }
        guard !inputDevices.isEmpty else {
            print("No non-aggregate input devices available for testing")
            return
        }

        let uids = inputDevices.prefix(2).map { $0.uid }
        let aggID = manager.createAggregateInputDevice(
            name: "Test Multi-Mic Aggregate",
            subDeviceUIDs: Array(uids),
            isPrivate: false
        )

        XCTAssertNotNil(aggID, "Should successfully create aggregate input device")
        if let id = aggID {
            var dev: AudioDevice?
            for _ in 0..<10 {
                dev = AudioDeviceManager.shared.refreshDevices().first { $0.id == id }
                if dev != nil { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            XCTAssertNotNil(dev, "Created aggregate device must be discoverable")
            XCTAssertTrue(dev?.isInput == true, "Created aggregate device must have input channels")
            XCTAssertGreaterThan(dev?.inputChannelCount ?? 0, 0, "Aggregate device should have > 0 input channels")

            manager.destroyDevice(id: id)
        }
    }

    func testMicrophoneInputSourceLifecycle() {
        let inputDevices = AudioDeviceManager.shared.getInputDevices()
        guard let firstInput = inputDevices.first else {
            print("No input devices available for testing")
            return
        }

        let source = MicrophoneInputSource(deviceID: firstInput.id, deviceUID: firstInput.uid)
        XCTAssertEqual(source.volume, 1.0)
        XCTAssertFalse(source.isMuted)
        XCTAssertFalse(source.routeToVirtualMic)

        source.volume = 1.2
        XCTAssertEqual(source.volume, 1.2)

        source.isMuted = true
        XCTAssertTrue(source.isMuted)

        source.routeToVirtualMic = true
        XCTAssertTrue(source.routeToVirtualMic)

        let started = source.start()
        XCTAssertTrue(started, "MicrophoneInputSource should start successfully")
        XCTAssertTrue(source.isRunning)

        // Sleep briefly to let IOProc capture a buffer
        Thread.sleep(forTimeInterval: 0.1)

        source.stop()
        XCTAssertFalse(source.isRunning)
    }
}

import XCTest
import CoreAudio
@testable import AppAudioRouterCore

final class AggregateDeviceManagerTests: XCTestCase {
    func testAggregateRejectsMissingSubdevice() {
        let manager = AggregateDeviceManager()
        XCTAssertNil(manager.createAggregateInputDevice(
            subDeviceUIDs: ["com.appaudiorouter.tests.missing.\(UUID().uuidString)"]
        ))
    }
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

    func testVirtualMicrophonePersistentUID() {
        XCTAssertEqual(AggregateDeviceManager.virtualMicUID, "com.appaudiorouter.virtualmic.default")
        XCTAssertEqual(AggregateDeviceManager.virtualMicDeviceName, "AppAudioRouter Virtual Microphone")
    }

    func testVirtualMicrophoneCreationIsIdempotent() throws {
        let manager = AggregateDeviceManager()
        let devices = AudioDeviceManager.shared.refreshDevices()
        guard !devices.contains(where: { $0.uid == AggregateDeviceManager.virtualMicUID }) else {
            throw XCTSkip("A running app already owns the virtual microphone; do not disturb it")
        }
        let source = AudioDeviceManager.shared.getAllDevices().first {
            $0.isInput && $0.isOutput && !$0.isAggregate &&
            ($0.uid.lowercased().contains("blackhole") || $0.uid.contains("zoom.us.zoomaudiodevice"))
        }
        guard let source else {
            print("No bidirectional loopback device available for virtual microphone test")
            return
        }

        let originalDefaultInput = AudioDeviceManager.shared.getDefaultInputDevice()?.id
        let firstID = manager.createVirtualMicrophone(subDeviceUID: source.uid)
        let secondID = manager.createVirtualMicrophone(subDeviceUID: source.uid)
        defer { manager.destroyVirtualMicrophone() }

        XCTAssertNotNil(firstID)
        XCTAssertEqual(secondID, firstID, "Repeated setup should reuse the same aggregate device")
        let borrower = AggregateDeviceManager()
        XCTAssertEqual(borrower.createVirtualMicrophone(subDeviceUID: source.uid), firstID)
        borrower.destroyVirtualMicrophone()
        borrower.destroyAll()
        XCTAssertTrue(AudioDeviceManager.shared.refreshDevices().contains { $0.id == firstID },
                      "A second manager must not destroy a borrowed virtual microphone")
        XCTAssertEqual(AudioDeviceManager.shared.getDefaultInputDevice()?.id, originalDefaultInput,
                       "Creating the virtual microphone must not change macOS default input")
    }

    func testCombinedMicrophonesCannotMasqueradeAsDesktopVirtualMic() {
        let combined = AudioDevice(id: 1, uid: "com.appaudiorouter.aggregatemic.test",
                                   name: AggregateDeviceManager.virtualMicDeviceName,
                                   manufacturer: "Test", isInput: true, isOutput: true,
                                   isAggregate: true)
        XCTAssertFalse(combined.isAppVirtualMicrophone)
        let dedicated = AudioDevice(id: 2, uid: AggregateDeviceManager.virtualMicUID,
                                    name: "Renamed device", manufacturer: "Test",
                                    isInput: true, isOutput: true, isAggregate: true)
        XCTAssertTrue(dedicated.isAppVirtualMicrophone)
    }
}

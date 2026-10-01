import XCTest
import CoreAudio
@testable import AppAudioRouterCore

final class AudioDeviceManagerTests: XCTestCase {
    func testDeviceEnumeration() {
        let manager = AudioDeviceManager.shared
        let devices = manager.refreshDevices()

        XCTAssertFalse(devices.isEmpty, "System should report at least one audio device")

        let outputs = manager.getOutputDevices()
        XCTAssertFalse(outputs.isEmpty, "System should report at least one output device")

        let defaultOutput = manager.getDefaultOutputDevice()
        XCTAssertNotNil(defaultOutput, "System should have a default output device")

        if let defaultOut = defaultOutput {
            XCTAssertTrue(defaultOut.isOutput, "Default output device must have output channels")
            XCTAssertFalse(defaultOut.name.isEmpty, "Device must have a non-empty name")
            XCTAssertFalse(defaultOut.uid.isEmpty, "Device must have a non-empty UID")
        }
    }
}

import Foundation
import CoreAudio

/// Automatically creates and manages Multi-Output and Aggregate audio devices via CoreAudio HAL.
public final class AggregateDeviceManager: @unchecked Sendable {
    public static let shared = AggregateDeviceManager()

    private let lock = NSLock()
    private var managedDeviceIDs: Set<AudioObjectID> = []

    public init() {}

    deinit {
        destroyAll()
    }

    /// Automatically constructs a Multi-Output (Stacked) Aggregate Device.
    /// All sub-devices receive the same audio data simultaneously.
    /// If all specified devices are input-only (microphones), automatically creates
    /// a standard aggregate input device instead to ensure input channels are preserved.
    /// - Parameters:
    ///   - name: Human-readable device name shown in macOS.
    ///   - subDeviceUIDs: Array of device UIDs to combine.
    ///   - masterUID: The clock master device UID (defaults to the first device).
    ///   - isPrivate: Whether the device is private to this app or published system-wide.
    /// - Returns: The created AudioObjectID on success, or nil on failure.
    public func createMultiOutputDevice(
        name: String = "AppAudioRouter Multi-Output",
        subDeviceUIDs: [String],
        masterUID: String? = nil,
        isPrivate: Bool = false
    ) -> AudioObjectID? {
        guard !subDeviceUIDs.isEmpty else { return nil }

        // Check if all subdevices are input-only devices (microphones).
        // Stacked devices (isStacked == 1) strictly discard input channels in CoreAudio.
        let allDevices = AudioDeviceManager.shared.getAllDevices()
        let subDevs = subDeviceUIDs.compactMap { uid in allDevices.first { $0.uid == uid } }
        let allAreInputOnly = !subDevs.isEmpty && subDevs.allSatisfy { $0.isInput && !$0.isOutput }

        return createAggregateDevice(
            name: name,
            subDeviceUIDs: subDeviceUIDs,
            masterUID: masterUID,
            isStacked: !allAreInputOnly,
            isPrivate: isPrivate
        )
    }

    /// Automatically constructs an Aggregate Input Device (Multi-Mic).
    /// Combines input channels from multiple microphones into a single aggregate audio device.
    /// - Parameters:
    ///   - name: Human-readable device name shown in macOS.
    ///   - subDeviceUIDs: Array of microphone device UIDs to combine.
    ///   - masterUID: The clock master device UID (defaults to the first microphone).
    ///   - isPrivate: Whether the device is private to this app or published system-wide.
    /// - Returns: The created AudioObjectID on success, or nil on failure.
    public func createAggregateInputDevice(
        name: String = "AppAudioRouter Aggregate Mic",
        subDeviceUIDs: [String],
        masterUID: String? = nil,
        isPrivate: Bool = false
    ) -> AudioObjectID? {
        return createAggregateDevice(
            name: name,
            subDeviceUIDs: subDeviceUIDs,
            masterUID: masterUID,
            isStacked: false,
            isPrivate: isPrivate
        )
    }

    /// Generic aggregate device creation supporting both Multi-Output (stacked) and standard Aggregate (non-stacked) devices.
    /// - Parameters:
    ///   - name: Human-readable device name shown in macOS.
    ///   - subDeviceUIDs: Array of device UIDs to combine.
    ///   - masterUID: Clock master device UID (defaults to the first device).
    ///   - isStacked: If true, creates a Multi-Output device (outputs mirrored). If false, creates an Aggregate Device (combines channels).
    ///   - isPrivate: Whether the device is private to this app or published system-wide.
    /// - Returns: The created AudioObjectID on success, or nil on failure.
    public func createAggregateDevice(
        name: String,
        subDeviceUIDs: [String],
        masterUID: String? = nil,
        isStacked: Bool,
        isPrivate: Bool = false
    ) -> AudioObjectID? {
        guard !subDeviceUIDs.isEmpty else { return nil }

        let allDevices = AudioDeviceManager.shared.getAllDevices()
        let validUIDs = subDeviceUIDs.filter { uid in
            guard let dev = allDevices.first(where: { $0.uid == uid }) else { return true }
            return !dev.isAggregate
        }
        guard !validUIDs.isEmpty else { return nil }

        let master = masterUID ?? validUIDs[0]

        var subDevices: [[String: Any]] = []
        for uid in validUIDs {
            let subDict: [String: Any] = [
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceDriftCompensationKey: (uid == master) ? 0 : 1
            ]
            subDevices.append(subDict)
        }

        let prefix = isStacked ? "multiout" : "aggregatemic"
        let deviceUID = "com.appaudiorouter.\(prefix).\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: master,
            kAudioAggregateDeviceIsStackedKey: isStacked ? 1 : 0,
            kAudioAggregateDeviceIsPrivateKey: isPrivate ? 1 : 0
        ]

        var newDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newDeviceID)
        guard status == noErr, newDeviceID != 0 else {
            return nil
        }

        lock.lock()
        managedDeviceIDs.insert(newDeviceID)
        lock.unlock()

        AudioDeviceManager.shared.refreshDevices()
        return newDeviceID
    }

    /// Destroys a managed aggregate device.
    public func destroyDevice(id: AudioObjectID) {
        lock.lock()
        let wasManaged = managedDeviceIDs.remove(id) != nil
        lock.unlock()

        if wasManaged {
            AudioHardwareDestroyAggregateDevice(id)
            AudioDeviceManager.shared.refreshDevices()
        }
    }

    /// Destroys all aggregate devices created by this manager.
    public func destroyAll() {
        lock.lock()
        let toDestroy = managedDeviceIDs
        managedDeviceIDs.removeAll()
        lock.unlock()

        for id in toDestroy {
            AudioHardwareDestroyAggregateDevice(id)
        }
        if !toDestroy.isEmpty {
            AudioDeviceManager.shared.refreshDevices()
        }
    }

    /// Retrieves all sub-device UIDs contained in an aggregate device.
    public func getSubDeviceUIDs(for deviceID: AudioObjectID) -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioAggregateDevicePropertyActiveSubDeviceList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeErr == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var subIDs = [AudioObjectID](repeating: 0, count: count)
        let dataErr = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &subIDs)
        guard dataErr == noErr else { return [] }

        let allDevs = AudioDeviceManager.shared.getAllDevices()
        return subIDs.compactMap { sid in allDevs.first { $0.id == sid }?.uid }
    }

    /// Destroys any aggregate devices matching the given name.
    public func destroyDeviceByName(_ name: String) {
        let allDevs = AudioDeviceManager.shared.refreshDevices()
        for dev in allDevs where dev.name == name {
            AudioHardwareDestroyAggregateDevice(dev.id)
        }
        AudioDeviceManager.shared.refreshDevices()
    }

    /// Official name for the ephemeral virtual microphone published by AppAudioRouter.
    public static let virtualMicDeviceName = "AppAudioRouter Virtual Microphone"

    /// Automatically constructs the ephemeral AppAudioRouter Virtual Microphone wrapping the loopback sub-device.
    /// Destroyed automatically when AppAudioRouter terminates.
    @discardableResult
    public func createVirtualMicrophone(subDeviceUID: String) -> AudioObjectID? {
        destroyDeviceByName(AggregateDeviceManager.virtualMicDeviceName)
        destroyDeviceByName("Desktop Input Microphone")

        return createAggregateInputDevice(
            name: AggregateDeviceManager.virtualMicDeviceName,
            subDeviceUIDs: [subDeviceUID],
            isPrivate: false
        )
    }

    /// Destroys the ephemeral AppAudioRouter Virtual Microphone.
    public func destroyVirtualMicrophone() {
        destroyDeviceByName(AggregateDeviceManager.virtualMicDeviceName)
        destroyDeviceByName("Desktop Input Microphone")
    }
}

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
    ///   - deviceUID: Optional deterministic unique identifier for the aggregate device.
    ///   - isPrivate: Whether the device is private to this app or published system-wide.
    /// - Returns: The created AudioObjectID on success, or nil on failure.
    public func createAggregateInputDevice(
        name: String = "AppAudioRouter Aggregate Mic",
        subDeviceUIDs: [String],
        masterUID: String? = nil,
        deviceUID: String? = nil,
        isPrivate: Bool = false
    ) -> AudioObjectID? {
        return createAggregateDevice(
            name: name,
            subDeviceUIDs: subDeviceUIDs,
            masterUID: masterUID,
            deviceUID: deviceUID,
            isStacked: false,
            isPrivate: isPrivate
        )
    }

    /// Generic aggregate device creation supporting both Multi-Output (stacked) and standard Aggregate (non-stacked) devices.
    /// - Parameters:
    ///   - name: Human-readable device name shown in macOS.
    ///   - subDeviceUIDs: Array of device UIDs to combine.
    ///   - masterUID: Clock master device UID (defaults to the first device).
    ///   - deviceUID: Optional custom persistent UID. If nil, generates a unique UID with UUID.
    ///   - isStacked: If true, creates a Multi-Output device (outputs mirrored). If false, creates an Aggregate Device (combines channels).
    ///   - isPrivate: Whether the device is private to this app or published system-wide.
    /// - Returns: The created AudioObjectID on success, or nil on failure.
    public func createAggregateDevice(
        name: String,
        subDeviceUIDs: [String],
        masterUID: String? = nil,
        deviceUID customUID: String? = nil,
        isStacked: Bool,
        isPrivate: Bool = false
    ) -> AudioObjectID? {
        guard !subDeviceUIDs.isEmpty else { return nil }

        let allDevices = AudioDeviceManager.shared.getAllDevices()
        let validUIDs = subDeviceUIDs.filter { uid in
            guard let dev = allDevices.first(where: { $0.uid == uid }) else { return false }
            return !dev.isAggregate
        }
        guard validUIDs.count == subDeviceUIDs.count else { return nil }

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
        let deviceUID = customUID ?? "com.appaudiorouter.\(prefix).\(UUID().uuidString)"

        if let custom = customUID {
            destroyDeviceByUID(custom)
        }

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

    /// Retrieves configured sub-device UIDs, including temporarily inactive devices.
    public func getSubDeviceUIDs(for deviceID: AudioObjectID) -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioAggregateDevicePropertyFullSubDeviceList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return [] }
        return value.takeRetainedValue() as? [String] ?? []
    }

    /// Destroys any aggregate devices matching the given name.
    public func destroyDeviceByName(_ name: String) {
        let allDevs = AudioDeviceManager.shared.refreshDevices()
        for dev in allDevs where dev.name == name {
            lock.lock()
            managedDeviceIDs.remove(dev.id)
            lock.unlock()
            AudioHardwareDestroyAggregateDevice(dev.id)
        }
        AudioDeviceManager.shared.refreshDevices()
    }

    /// Destroys any aggregate devices matching the given UID.
    public func destroyDeviceByUID(_ uid: String) {
        let allDevs = AudioDeviceManager.shared.refreshDevices()
        for dev in allDevs where dev.uid == uid {
            lock.lock()
            managedDeviceIDs.remove(dev.id)
            lock.unlock()
            AudioHardwareDestroyAggregateDevice(dev.id)
        }
        AudioDeviceManager.shared.refreshDevices()
    }

    /// Official name for the ephemeral virtual microphone published by AppAudioRouter.
    public static let virtualMicDeviceName = "AppAudioRouter Virtual Microphone"

    /// Deterministic, static UID for the ephemeral virtual microphone to maintain browser/WebRTC binding across app sessions.
    public static let virtualMicUID = "com.appaudiorouter.virtualmic.default"

    /// Automatically constructs the ephemeral AppAudioRouter Virtual Microphone wrapping the loopback sub-device.
    /// Destroyed automatically when AppAudioRouter terminates.
    @discardableResult
    public func createVirtualMicrophone(subDeviceUID: String) -> AudioObjectID? {
        let devices = AudioDeviceManager.shared.refreshDevices()
        if let existing = devices.first(where: { $0.uid == Self.virtualMicUID }),
           existing.name == Self.virtualMicDeviceName,
           existing.isAggregate,
           getSubDeviceUIDs(for: existing.id) == [subDeviceUID] {
            // Reusing another process's device does not transfer ownership.
            // A CLI invocation or test must not remove the running app's microphone.
            return existing.id
        }

        if let existing = devices.first(where: { $0.uid == Self.virtualMicUID }) {
            lock.lock()
            let isOwned = managedDeviceIDs.contains(existing.id)
            lock.unlock()
            // A temporary format/availability change is not permission to tear
            // down a microphone published by a different process.
            guard isOwned else { return nil }
            destroyDevice(id: existing.id)
        }

        return createAggregateInputDevice(
            name: AggregateDeviceManager.virtualMicDeviceName,
            subDeviceUIDs: [subDeviceUID],
            deviceUID: AggregateDeviceManager.virtualMicUID,
            isPrivate: false
        )
    }

    /// Destroys the ephemeral AppAudioRouter Virtual Microphone.
    public func destroyVirtualMicrophone() {
        let devices = AudioDeviceManager.shared.refreshDevices()
        for device in devices where device.uid == Self.virtualMicUID {
            destroyDevice(id: device.id)
        }
    }
}

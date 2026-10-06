import Foundation
import CoreAudio

/// Manages enumeration, observation, and configuration of CoreAudio hardware devices.
public final class AudioDeviceManager: @unchecked Sendable {
    public static let shared = AudioDeviceManager()

    private let lock = NSLock()
    private var cachedDevices: [AudioDevice] = []
    public var onDevicesChanged: (@Sendable ([AudioDevice]) -> Void)?

    private var devicesPropertyListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {
        refreshDevices()
        setupListeners()
    }

    deinit {
        removeListeners()
    }

    // MARK: - Public Queries

    public func getAllDevices() -> [AudioDevice] {
        lock.lock()
        defer { lock.unlock() }
        return cachedDevices
    }

    public func getOutputDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.isOutput }
    }

    public func getInputDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.isInput }
    }

    public func getVirtualDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.isVirtual }
    }

    public func getDefaultOutputDevice() -> AudioDevice? {
        return getAllDevices().first { $0.isDefaultOutput }
    }

    public func getDefaultInputDevice() -> AudioDevice? {
        return getAllDevices().first { $0.isDefaultInput }
    }

    public func findDevice(byUID uid: String) -> AudioDevice? {
        return getAllDevices().first { $0.uid == uid }
    }

    public func findDevice(byID id: AudioObjectID) -> AudioDevice? {
        return getAllDevices().first { $0.id == id }
    }

    // MARK: - Default Device Control

    public func setDefaultOutputDevice(id: AudioObjectID) -> Bool {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        if status == noErr {
            refreshDevices()
            return true
        }
        return false
    }

    public func setDefaultInputDevice(id: AudioObjectID) -> Bool {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultInputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        if status == noErr {
            refreshDevices()
            return true
        }
        return false
    }

    // MARK: - Refresh & Enumeration

    @discardableResult
    public func refreshDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        let defaultOutputID = queryDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInputID = queryDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultSystemOutputID = queryDefaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)

        var newDevices: [AudioDevice] = []
        for id in deviceIDs {
            if let device = createAudioDevice(
                id: id,
                defaultOutputID: defaultOutputID,
                defaultInputID: defaultInputID,
                defaultSystemOutputID: defaultSystemOutputID
            ) {
                newDevices.append(device)
            }
        }

        lock.lock()
        self.cachedDevices = newDevices
        let callback = self.onDevicesChanged
        lock.unlock()

        callback?(newDevices)
        return newDevices
    }

    // MARK: - Private Helpers

    private func queryDefaultDevice(selector: AudioHardwarePropertyID) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private func createAudioDevice(
        id: AudioObjectID,
        defaultOutputID: AudioObjectID,
        defaultInputID: AudioObjectID,
        defaultSystemOutputID: AudioObjectID
    ) -> AudioDevice? {
        guard let uid = getStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        let name = getStringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Audio Device \(id)"
        let manufacturer = getStringProperty(id: id, selector: kAudioObjectPropertyManufacturer) ?? "Unknown"

        let inChannels = getChannelCount(id: id, scope: kAudioDevicePropertyScopeInput)
        let outChannels = getChannelCount(id: id, scope: kAudioDevicePropertyScopeOutput)

        let isInput = inChannels > 0
        let isOutput = outChannels > 0
        guard isInput || isOutput else { return nil }

        let sampleRate = getSampleRate(id: id)
        let isVirtual = checkIsVirtual(id: id)
        let isAggregate = checkIsAggregate(id: id, uid: uid)

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            isInput: isInput,
            isOutput: isOutput,
            isDefaultOutput: id == defaultOutputID,
            isDefaultInput: id == defaultInputID,
            isDefaultSystemOutput: id == defaultSystemOutputID,
            isVirtual: isVirtual,
            isAggregate: isAggregate,
            sampleRate: sampleRate,
            inputChannelCount: inChannels,
            outputChannelCount: outChannels
        )
    }

    private func getStringProperty(id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var unmanagedStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanagedStr)
        if status == noErr, let str = unmanagedStr?.takeRetainedValue() as String? {
            return str
        }
        return nil
    }

    private func getChannelCount(id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration),
            mScope: scope,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }

        let getStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferListPtr)
        guard getStatus == noErr else { return 0 }

        let audioBufferList = bufferListPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var channelCount = 0
        for buffer in list {
            channelCount += Int(buffer.mNumberChannels)
        }
        return channelCount
    }

    private func getSampleRate(id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var rate: Float64 = 48000.0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr ? Double(rate) : 48000.0
    }

    private func checkIsVirtual(id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyTransportType),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        if status == noErr && transport == kAudioDeviceTransportTypeVirtual {
            return true
        }
        // Also check by name heuristics
        if let name = getStringProperty(id: id, selector: kAudioObjectPropertyName)?.lowercased() {
            if name.contains("blackhole") || name.contains("virtual") || name.contains("teams") || name.contains("zoom") || name.contains("loopback") {
                return true
            }
        }
        return false
    }

    private func checkIsAggregate(id: AudioObjectID, uid: String) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyTransportType),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        if status == noErr && transport == kAudioDeviceTransportTypeAggregate {
            return true
        }
        if uid.contains("aggregate") || uid.contains("multiout") || uid.contains("tapagg") {
            return true
        }
        return false
    }

    // MARK: - Listeners

    private func setupListeners() {
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] (_, _) in
            guard let self = self else { return }
            _ = self.refreshDevices()
        }
        self.devicesPropertyListenerBlock = listenerBlock

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.global(qos: .utility),
            listenerBlock
        )

        var defaultOutAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddress,
            DispatchQueue.global(qos: .utility),
            listenerBlock
        )

        var defaultInAddress = AudioObjectPropertyAddress(
            mSelector: AudioHardwarePropertyID(kAudioHardwarePropertyDefaultInputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInAddress,
            DispatchQueue.global(qos: .utility),
            listenerBlock
        )
    }

    private func removeListeners() {
        guard let block = devicesPropertyListenerBlock else { return }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.global(qos: .utility),
            block
        )

        var defaultOutAddress = AudioObjectPropertyAddress(
            mSelector: AudioHardwarePropertyID(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddress,
            DispatchQueue.global(qos: .utility),
            block
        )
        var defaultInAddress = AudioObjectPropertyAddress(
            mSelector: AudioHardwarePropertyID(kAudioHardwarePropertyDefaultInputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInAddress,
            DispatchQueue.global(qos: .utility),
            block
        )
    }
}

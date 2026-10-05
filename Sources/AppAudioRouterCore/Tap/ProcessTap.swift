import Foundation
import CoreAudio

/// Manages a CoreAudio Process Tap for a target process object.
@available(macOS 14.2, *)
public final class ProcessTap: @unchecked Sendable {
    public let processObjectID: AudioObjectID
    public let processObjectIDs: [AudioObjectID]
    public let pid: pid_t
    public let uuid: UUID
    public private(set) var tapID: AudioObjectID = 0
    public private(set) var tapUID: String = ""
    public private(set) var isActive: Bool = false

    public init(processObjectID: AudioObjectID, pid: pid_t) {
        self.processObjectID = processObjectID
        self.processObjectIDs = (processObjectID != 0) ? [processObjectID] : []
        self.pid = pid
        self.uuid = UUID()
    }

    public init(processObjectIDs: [AudioObjectID], pid: pid_t) {
        self.processObjectID = processObjectIDs.first ?? 0
        self.processObjectIDs = processObjectIDs.filter { $0 != 0 }
        self.pid = pid
        self.uuid = UUID()
    }

    deinit {
        destroy()
    }

    /// Creates and activates the CoreAudio Process Tap.
    /// - Parameter muteOriginal: If true, mutes the process output to the default audio hardware so it can be redirected.
    public func create(muteOriginal: Bool = false) -> Bool {
        guard !isActive else { return true }

        let targetIDs = processObjectIDs.isEmpty ? (processObjectID != 0 ? [processObjectID] : []) : processObjectIDs
        guard !targetIDs.isEmpty else { return false }

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: targetIDs)
        tapDesc.name = "AppAudioRouterTap-\(pid)"
        tapDesc.uuid = uuid
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = muteOriginal ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted

        var newTapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr, newTapID != 0 else {
            return false
        }

        self.tapID = newTapID

        // Retrieve the Tap UID
        var tapUIDAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioTapPropertyUID),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var unmanagedUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidErr = AudioObjectGetPropertyData(newTapID, &tapUIDAddress, 0, nil, &size, &unmanagedUID)
        if uidErr == noErr, let uid = unmanagedUID?.takeRetainedValue() as String? {
            self.tapUID = uid
            self.isActive = true
            return true
        } else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = 0
            return false
        }
    }

    /// Updates mute behavior of the existing tap.
    public func setMuteOriginal(_ mute: Bool) {
        guard isActive, tapID != 0 else { return }
        let targetIDs = processObjectIDs.isEmpty ? (processObjectID != 0 ? [processObjectID] : []) : processObjectIDs
        guard !targetIDs.isEmpty else { return }

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: targetIDs)
        tapDesc.name = "AppAudioRouterTap-\(pid)"
        tapDesc.uuid = uuid
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = mute ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted

        var tapDescAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioTapPropertyDescription),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        let desc = tapDesc
        let size = UInt32(MemoryLayout<CATapDescription>.size)
        withUnsafePointer(to: desc) { ptr in
            _ = AudioObjectSetPropertyData(tapID, &tapDescAddress, 0, nil, size, ptr)
        }
    }

    /// Destroys the Process Tap.
    public func destroy() {
        guard isActive, tapID != 0 else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = 0
        tapUID = ""
        isActive = false
    }

    /// Retrieves CoreAudio process object IDs for a given PID (defaults to current process).
    public static func getProcessObjectIDs(for pid: pid_t = getpid()) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs)
        guard status == noErr else { return [] }

        var matching: [AudioObjectID] = []
        for objID in processIDs {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioProcessPropertyPID),
                mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
            )
            var p: pid_t = 0
            var s = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &s, &p) == noErr, p == pid {
                matching.append(objID)
            }
        }
        return matching
    }

    /// Creates a system-wide global desktop audio tap.
    /// Captures all desktop sound (except excluded processes).
    /// Automatically excludes the calling application to prevent feedback loops when routing back to a virtual device.
    public static func createGlobalTap(
        excludeProcesses: [AudioObjectID] = [],
        muteOriginal: Bool = false
    ) -> (tapID: AudioObjectID, tapUID: String)? {
        let ownIDs = getProcessObjectIDs()
        let combinedExclusions = Array(Set(excludeProcesses + ownIDs))

        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: combinedExclusions)
        tapDesc.name = "AppAudioRouterDesktopTap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = muteOriginal ? .muted : .unmuted

        var newTapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr, newTapID != 0 else { return nil }

        var tapUIDAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioTapPropertyUID),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var unmanagedUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidErr = AudioObjectGetPropertyData(newTapID, &tapUIDAddress, 0, nil, &size, &unmanagedUID)
        if uidErr == noErr, let uid = unmanagedUID?.takeRetainedValue() as String? {
            return (newTapID, uid)
        } else {
            AudioHardwareDestroyProcessTap(newTapID)
            return nil
        }
    }

    /// Resolves app-level exclusions to the CoreAudio process objects currently owned by those apps.
    /// Bundle identifier prefix matching includes Chromium helper processes while preserving app-level UI.
    public static func processObjectIDs(
        forBundleIdentifiers bundleIdentifiers: Set<String>,
        processes: [AudioProcess]
    ) -> [AudioObjectID] {
        let ids = processes.compactMap { process -> [AudioObjectID]? in
            guard let bundleID = process.bundleIdentifier,
                  bundleIdentifiers.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) else {
                return nil
            }
            return process.objectIDs
        }.flatMap { $0 }
        return Array(Set(ids)).sorted()
    }
}

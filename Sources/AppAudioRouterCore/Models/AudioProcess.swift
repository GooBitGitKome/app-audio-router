import Foundation
import CoreAudio
import AppKit

/// Represents an application or process actively communicating with CoreAudio.
public struct AudioProcess: Identifiable, Sendable {
    public var id: pid_t { pid }
    public let objectID: AudioObjectID
    public let objectIDs: [AudioObjectID]
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let name: String
    public let isSystemDaemon: Bool
    public let isAudioActive: Bool
    
    public init(
        objectID: AudioObjectID,
        objectIDs: [AudioObjectID] = [],
        pid: pid_t,
        bundleIdentifier: String?,
        name: String,
        isSystemDaemon: Bool = false,
        isAudioActive: Bool = true
    ) {
        self.objectID = objectID
        self.objectIDs = objectIDs.isEmpty ? (objectID != 0 ? [objectID] : []) : objectIDs
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isSystemDaemon = isSystemDaemon
        self.isAudioActive = isAudioActive
    }
}

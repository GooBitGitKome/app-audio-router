import Foundation
import CoreAudio

/// Represents a physical or virtual CoreAudio device on macOS.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let isInput: Bool
    public let isOutput: Bool
    public let isDefaultOutput: Bool
    public let isDefaultInput: Bool
    public let isDefaultSystemOutput: Bool
    public let isVirtual: Bool
    public let isAggregate: Bool
    public let sampleRate: Double
    public let inputChannelCount: Int
    public let outputChannelCount: Int

    /// Only the dedicated desktop loopback wrapper has this identity.
    /// User-created Combined Microphones devices must not be used in its place.
    public var isAppVirtualMicrophone: Bool {
        isInput && isAggregate && uid == AggregateDeviceManager.virtualMicUID
    }

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        manufacturer: String,
        isInput: Bool,
        isOutput: Bool,
        isDefaultOutput: Bool = false,
        isDefaultInput: Bool = false,
        isDefaultSystemOutput: Bool = false,
        isVirtual: Bool = false,
        isAggregate: Bool = false,
        sampleRate: Double = 48000.0,
        inputChannelCount: Int = 0,
        outputChannelCount: Int = 0
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.isInput = isInput
        self.isOutput = isOutput
        self.isDefaultOutput = isDefaultOutput
        self.isDefaultInput = isDefaultInput
        self.isDefaultSystemOutput = isDefaultSystemOutput
        self.isVirtual = isVirtual
        self.isAggregate = isAggregate
        self.sampleRate = sampleRate
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
    }
}

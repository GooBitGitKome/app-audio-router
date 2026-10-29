import Foundation
import CoreAudio

/// Encapsulates a private CoreAudio Aggregate Device wrapping an AudioTap,
/// enabling real-time PCM audio buffer capture via AudioDeviceIOProc.
public final class TapAggregateDevice: @unchecked Sendable {
    public let tapUID: String
    public let deviceName: String
    public private(set) var aggregateDeviceID: AudioObjectID = 0
    public private(set) var isRunning: Bool = false

    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.appaudiorouter.io", qos: .userInteractive)

    public var targetSampleRate: Float64
    public var onAudioBuffer: (@Sendable (UnsafePointer<AudioBufferList>) -> Void)?

    public init(tapUID: String, deviceName: String = "AppAudioRouterTapDevice", targetSampleRate: Float64 = 48000.0) {
        self.tapUID = tapUID
        self.deviceName = "\(deviceName)-\(tapUID.prefix(8))"
        self.targetSampleRate = targetSampleRate
    }

    deinit {
        stop()
        destroy()
    }

    /// Creates the private aggregate device linking the tap.
    public func create() -> Bool {
        guard aggregateDeviceID == 0 else { return true }

        let subTapDict: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1
        ]
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceName,
            kAudioAggregateDeviceUIDKey: "com.appaudiorouter.tapagg.\(tapUID)",
            kAudioAggregateDeviceTapListKey: [subTapDict],
            kAudioAggregateDeviceIsPrivateKey: 1
        ]

        var newDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &newDeviceID)
        guard status == noErr, newDeviceID != 0 else {
            return false
        }

        self.aggregateDeviceID = newDeviceID

        // Synchronize aggregate device sample rate with target output device to prevent clock drift and buffer underruns
        if targetSampleRate > 0 {
            var rate = targetSampleRate
            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let setStatus = AudioObjectSetPropertyData(newDeviceID, &rateAddr, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
            var actualRate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            let readStatus = AudioObjectGetPropertyData(newDeviceID, &rateAddr, 0, nil, &size, &actualRate)
            // A failed write is harmless only when the device already has the
            // requested rate. Never publish an unverified capture clock.
            guard readStatus == noErr, abs(actualRate - targetSampleRate) < 0.5 else {
                NSLog("Tap sample rate verification failed: set=%d read=%d requested=%f actual=%f", setStatus, readStatus, targetSampleRate, actualRate)
                destroy()
                return false
            }
        }

        return true
    }

    /// Starts real-time capture from the aggregate device.
    public func start() -> Bool {
        if aggregateDeviceID == 0 {
            guard create() else { return false }
        }
        guard !isRunning else { return true }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            ioQueue
        ) { [weak self] (_, inInputData, _, _, _) in
            guard let self = self else { return }
            self.onAudioBuffer?(inInputData)
        }

        guard status == noErr, let validProcID = procID else {
            return false
        }

        self.ioProcID = validProcID
        let startStatus = AudioDeviceStart(aggregateDeviceID, validProcID)
        if startStatus == noErr {
            self.isRunning = true
            return true
        } else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validProcID)
            self.ioProcID = nil
            return false
        }
    }

    /// Stops audio capture.
    public func stop() {
        guard isRunning, let procID = ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, procID)
        AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        self.ioProcID = nil
        self.isRunning = false
    }

    /// Destroys the aggregate device.
    public func destroy() {
        stop()
        guard aggregateDeviceID != 0 else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = 0
    }
}

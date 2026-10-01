import Foundation
import CoreAudio
import Accelerate

/// Manages real-time capture from a physical or virtual input device (microphone),
/// handles mono-to-stereo expansion, gain/mute DSP, live peak level metering,
/// and streaming into an AudioRingBuffer for mixing.
public final class MicrophoneInputSource: @unchecked Sendable {
    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let sourceID = UUID()

    public private(set) var isRunning: Bool = false

    private let lock = NSLock()
    private var _volume: Float = 1.0
    private var _isMuted: Bool = false
    private var _routeToVirtualMic: Bool = false
    private var _peakLevel: Float = 0.0

    public var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return _volume }
        set { lock.lock(); _volume = max(0.0, min(newValue, 2.0)); lock.unlock() }
    }

    public var isMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isMuted }
        set { lock.lock(); _isMuted = newValue; lock.unlock() }
    }

    public var routeToVirtualMic: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _routeToVirtualMic }
        set { lock.lock(); _routeToVirtualMic = newValue; lock.unlock() }
    }

    public var peakLevel: Float {
        get { lock.lock(); defer { lock.unlock() }; return _peakLevel }
    }

    public let ringBuffer = AudioRingBuffer()
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.appaudiorouter.mic.input", qos: .userInteractive)

    public var onPeakLevelUpdate: (@Sendable (Float) -> Void)?

    public init(deviceID: AudioObjectID, deviceUID: String) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
    }

    deinit {
        stop()
    }

    /// Starts capturing audio from the microphone hardware.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            ioQueue
        ) { [weak self] (_, inInputData, _, _, _) in
            guard let self = self else { return }
            self.handleCapturedBuffer(bufferList: inInputData)
        }

        guard status == noErr, let validProcID = procID else {
            return false
        }

        self.ioProcID = validProcID
        let startStatus = AudioDeviceStart(deviceID, validProcID)
        if startStatus == noErr {
            self.isRunning = true
            return true
        } else {
            AudioDeviceDestroyIOProcID(deviceID, validProcID)
            self.ioProcID = nil
            return false
        }
    }

    /// Stops capturing audio.
    public func stop() {
        guard isRunning, let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.ioProcID = nil
        self.isRunning = false
        ringBuffer.clear()
    }

    private func handleCapturedBuffer(bufferList: UnsafePointer<AudioBufferList>) {
        let currentVol: Float
        let currentMuted: Bool
        let routeActive: Bool
        lock.lock()
        currentVol = _volume
        currentMuted = _isMuted
        routeActive = _routeToVirtualMic
        lock.unlock()

        let peak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)
        lock.lock()
        _peakLevel = peak
        lock.unlock()
        onPeakLevelUpdate?(peak)

        // Only stream to ring buffer if routing to virtual mic is enabled
        guard routeActive else { return }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

        if abl.count == 1 {
            let channelCount = max(1, Int(firstBuf.mNumberChannels))
            let frameCount = Int(firstBuf.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            guard frameCount > 0 else { return }
            let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channelCount)

            var stereoBuffer = [Float](repeating: 0.0, count: frameCount * 2)
            if !currentMuted && currentVol > 0.0001 {
                if channelCount == 1 {
                    for f in 0..<frameCount {
                        let sample = floatPtr[f] * currentVol
                        stereoBuffer[2 * f] = sample
                        stereoBuffer[2 * f + 1] = sample
                    }
                } else {
                    for f in 0..<frameCount {
                        stereoBuffer[2 * f] = floatPtr[channelCount * f] * currentVol
                        stereoBuffer[2 * f + 1] = floatPtr[channelCount * f + 1] * currentVol
                    }
                }
            }
            stereoBuffer.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                ringBuffer.write(frames: frameCount, from: base)
            }
        } else if abl.count >= 2 {
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let secondRaw = abl[1].mData else { return }
            let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
            let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

            var stereoBuffer = [Float](repeating: 0.0, count: frameCount * 2)
            if !currentMuted && currentVol > 0.0001 {
                for f in 0..<frameCount {
                    stereoBuffer[2 * f] = floatPtrL[f] * currentVol
                    stereoBuffer[2 * f + 1] = floatPtrR[f] * currentVol
                }
            }
            stereoBuffer.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                ringBuffer.write(frames: frameCount, from: base)
            }
        }
    }
}

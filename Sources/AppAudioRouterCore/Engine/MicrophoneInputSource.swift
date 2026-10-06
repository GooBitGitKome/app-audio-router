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

    private let volumeBits = RealtimeAtomicUInt32(Float(1.0).bitPattern)
    private let mutedFlag = RealtimeAtomicUInt32(0)
    private let routeFlag = RealtimeAtomicUInt32(0)
    private let peakBits = RealtimeAtomicUInt32(0)
    private let scratchSampleCapacity = 32_768
    private let scratchBuffer: UnsafeMutablePointer<Float>

    public var volume: Float {
        get { Float(bitPattern: volumeBits.load()) }
        set { volumeBits.store(max(0.0, min(newValue, 2.0)).bitPattern) }
    }

    public var isMuted: Bool {
        get { mutedFlag.load() != 0 }
        set { mutedFlag.store(newValue ? 1 : 0) }
    }

    public var routeToVirtualMic: Bool {
        get { routeFlag.load() != 0 }
        set { routeFlag.store(newValue ? 1 : 0) }
    }

    public var peakLevel: Float {
        get { Float(bitPattern: peakBits.load()) }
    }

    public let ringBuffer = AudioRingBuffer()
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.appaudiorouter.mic.input", qos: .userInteractive)
    private let meterQueue = DispatchQueue(label: "com.appaudiorouter.mic.meter", qos: .utility)
    private var meterTimer: DispatchSourceTimer?

    public var onPeakLevelUpdate: (@Sendable (Float) -> Void)?

    public init(deviceID: AudioObjectID, deviceUID: String) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.scratchBuffer = .allocate(capacity: scratchSampleCapacity)
        self.scratchBuffer.initialize(repeating: 0, count: scratchSampleCapacity)
    }

    deinit {
        stop()
        scratchBuffer.deinitialize(count: scratchSampleCapacity)
        scratchBuffer.deallocate()
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
            startMeterTimer()
            return true
        } else {
            AudioDeviceDestroyIOProcID(deviceID, validProcID)
            self.ioProcID = nil
            return false
        }
    }

    /// Stops capturing audio.
    public func stop() {
        meterTimer?.cancel()
        meterTimer = nil
        guard isRunning, let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.ioProcID = nil
        self.isRunning = false
        ringBuffer.clear()
        peakBits.store(0)
    }

    private func startMeterTimer() {
        guard meterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: meterQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.onPeakLevelUpdate?(Float(bitPattern: self.peakBits.load()))
        }
        meterTimer = timer
        timer.resume()
    }

    private func handleCapturedBuffer(bufferList: UnsafePointer<AudioBufferList>) {
        let currentVol = Float(bitPattern: volumeBits.load())
        let currentMuted = mutedFlag.load() != 0
        let routeActive = routeFlag.load() != 0
        let peak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)
        peakBits.store(peak.bitPattern)

        // Only stream to ring buffer if routing to virtual mic is enabled
        guard routeActive else { return }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

        if abl.count == 1 {
            let channelCount = max(1, Int(firstBuf.mNumberChannels))
            let frameCount = Int(firstBuf.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            guard frameCount > 0, frameCount * 2 <= scratchSampleCapacity else { return }
            let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channelCount)

            if currentMuted || currentVol <= 0.0001 {
                vDSP_vclr(scratchBuffer, 1, vDSP_Length(frameCount * 2))
            } else {
                if channelCount == 1 {
                    for f in 0..<frameCount {
                        let sample = floatPtr[f] * currentVol
                        scratchBuffer[2 * f] = sample
                        scratchBuffer[2 * f + 1] = sample
                    }
                } else {
                    for f in 0..<frameCount {
                        scratchBuffer[2 * f] = floatPtr[channelCount * f] * currentVol
                        scratchBuffer[2 * f + 1] = floatPtr[channelCount * f + 1] * currentVol
                    }
                }
            }
            ringBuffer.write(frames: frameCount, from: scratchBuffer)
        } else if abl.count >= 2 {
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, frameCount * 2 <= scratchSampleCapacity, let secondRaw = abl[1].mData else { return }
            let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
            let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

            if currentMuted || currentVol <= 0.0001 {
                vDSP_vclr(scratchBuffer, 1, vDSP_Length(frameCount * 2))
            } else {
                for f in 0..<frameCount {
                    scratchBuffer[2 * f] = floatPtrL[f] * currentVol
                    scratchBuffer[2 * f + 1] = floatPtrR[f] * currentVol
                }
            }
            ringBuffer.write(frames: frameCount, from: scratchBuffer)
        }
    }
}

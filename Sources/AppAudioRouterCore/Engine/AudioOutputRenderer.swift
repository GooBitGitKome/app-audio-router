import Foundation
import CoreAudio
import Accelerate

/// Manages real-time audio playback onto a target output device (physical speaker/headphones or virtual mic).
public final class AudioOutputRenderer: @unchecked Sendable {
    public let deviceID: AudioObjectID
    public let deviceUID: String
    public private(set) var isRunning: Bool = false

    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.appaudiorouter.renderer", qos: .userInteractive)

    private let lock = NSLock()
    private var sourceBuffers: [UUID: AudioRingBuffer] = [:]
    private let scratchSampleCapacity = 32_768
    private let scratchBuffer: UnsafeMutablePointer<Float>
    private let _renderCallCount = RealtimeAtomicUInt32(0)

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

    public func addSourceBuffer(id: UUID, buffer: AudioRingBuffer) {
        lock.lock()
        sourceBuffers[id] = buffer
        let shouldStart = !isRunning && !sourceBuffers.isEmpty
        lock.unlock()

        if shouldStart {
            _ = start()
        }
    }

    public func removeSourceBuffer(id: UUID) {
        lock.lock()
        sourceBuffers.removeValue(forKey: id)
        let shouldStop = isRunning && sourceBuffers.isEmpty
        lock.unlock()

        if shouldStop {
            stop()
        }
    }

    public func start() -> Bool {
        guard !isRunning else { return true }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            ioQueue
        ) { [weak self] (_, _, _, outOutputData, _) in
            guard let self = self else { return }
            self.renderAudio(to: outOutputData)
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

    public func stop() {
        guard isRunning, let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.ioProcID = nil
        self.isRunning = false
    }

    public var renderCallCount: UInt64 {
        UInt64(_renderCallCount.load())
    }

    private func renderAudio(to outputData: UnsafeMutablePointer<AudioBufferList>) {
        _renderCallCount.increment()

        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

        if abl.count == 1 {
            // Interleaved format (usually 2 channels in single buffer)
            let sampleCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            let destFloat = firstRaw.bindMemory(to: Float.self, capacity: sampleCount)

            // Zero the buffer initially
            vDSP_vclr(destFloat, 1, vDSP_Length(sampleCount))

            guard sampleCount <= scratchSampleCapacity, lock.try() else { return }
            defer { lock.unlock() }

            let channels = max(1, Int(firstBuf.mNumberChannels))
            let framesToRead = sampleCount / channels

            for ring in sourceBuffers.values {
                _ = ring.read(frames: framesToRead, into: scratchBuffer)
                vDSP_vadd(destFloat, 1, scratchBuffer, 1, destFloat, 1, vDSP_Length(sampleCount))
            }

            // Clamp mixed output to [-1.0, 1.0] to prevent harsh digital clipping
            var low: Float = -1.0
            var high: Float = 1.0
            vDSP_vclip(destFloat, 1, &low, &high, destFloat, 1, vDSP_Length(sampleCount))
        } else if abl.count >= 2 {
            // Planar format (buffer 0 = Left, buffer 1 = Right)
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let secondRaw = abl[1].mData else { return }

            let destL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
            let destR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

            vDSP_vclr(destL, 1, vDSP_Length(frameCount))
            vDSP_vclr(destR, 1, vDSP_Length(frameCount))

            guard frameCount * 2 <= scratchSampleCapacity, lock.try() else { return }
            defer { lock.unlock() }

            for ring in sourceBuffers.values {
                _ = ring.read(frames: frameCount, into: scratchBuffer)
                for f in 0..<frameCount {
                    destL[f] += scratchBuffer[f * 2]
                    destR[f] += scratchBuffer[f * 2 + 1]
                }
            }

            // Clamp mixed output to [-1.0, 1.0]
            var low: Float = -1.0
            var high: Float = 1.0
            vDSP_vclip(destL, 1, &low, &high, destL, 1, vDSP_Length(frameCount))
            vDSP_vclip(destR, 1, &low, &high, destR, 1, vDSP_Length(frameCount))
        }
    }
}

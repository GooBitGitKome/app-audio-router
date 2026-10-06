import Foundation
import CoreAudio

/// Thread-safe circular audio buffer for bridging input capture IOProcs and output rendering IOProcs.
public final class AudioRingBuffer: @unchecked Sendable {
    private let capacityFrames: Int
    private let channels: Int
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var availableFrames: Int = 0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    public init(capacityFrames: Int = 16384, channels: Int = 2) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.buffer = [Float](repeating: 0.0, count: capacityFrames * channels)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deallocate()
    }

    /// Writes interleaved float samples into the circular buffer.
    public func write(frames: Int, from source: UnsafePointer<Float>) {
        guard frames > 0 else { return }
        // Audio callbacks must never wait for the other side of the ring.
        // Dropping one input block is preferable to delaying a CoreAudio IOProc.
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }

        // If buffer would overflow, discard the oldest unread frames
        // to maintain low-latency and keep the real-time stream flowing smoothly.
        if availableFrames + frames > capacityFrames {
            let overflow = (availableFrames + frames) - capacityFrames
            readIndex = (readIndex + overflow) % capacityFrames
            availableFrames -= overflow
        }

        let framesToWrite = min(frames, capacityFrames - availableFrames)
        guard framesToWrite > 0 else { return }

        for f in 0..<framesToWrite {
            let bufferOffset = ((writeIndex + f) % capacityFrames) * channels
            let sourceOffset = f * channels
            for ch in 0..<channels {
                buffer[bufferOffset + ch] = source[sourceOffset + ch]
            }
        }

        writeIndex = (writeIndex + framesToWrite) % capacityFrames
        availableFrames += framesToWrite
    }

    /// Reads interleaved float samples from the circular buffer.
    /// Fills unread frames with silence (0.0).
    public func read(frames: Int, into destination: UnsafeMutablePointer<Float>) -> Int {
        guard frames > 0 else { return 0 }
        guard os_unfair_lock_trylock(lock) else {
            for sample in 0..<(frames * channels) {
                destination[sample] = 0.0
            }
            return 0
        }
        defer { os_unfair_lock_unlock(lock) }

        let framesToRead = min(frames, availableFrames)

        if framesToRead > 0 {
            for f in 0..<framesToRead {
                let bufferOffset = ((readIndex + f) % capacityFrames) * channels
                let destOffset = f * channels
                for ch in 0..<channels {
                    destination[destOffset + ch] = buffer[bufferOffset + ch]
                }
            }
            readIndex = (readIndex + framesToRead) % capacityFrames
            availableFrames -= framesToRead
        }

        // Fill remaining requested frames with silence
        if framesToRead < frames {
            let silenceCount = (frames - framesToRead) * channels
            let silenceOffset = framesToRead * channels
            for sample in 0..<silenceCount {
                destination[silenceOffset + sample] = 0.0
            }
        }

        return framesToRead
    }

    public func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writeIndex = 0
        readIndex = 0
        availableFrames = 0
    }
}

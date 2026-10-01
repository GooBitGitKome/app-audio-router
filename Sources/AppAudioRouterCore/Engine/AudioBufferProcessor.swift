import Foundation
import CoreAudio
import Accelerate

/// Performs real-time DSP operations: volume scaling, muting, and RMS/Peak level metering.
public struct AudioBufferProcessor: Sendable {

    /// Calculates peak and RMS amplitude from Float32 PCM audio buffers.
    /// Returns a normalized value between 0.0 and 1.0.
    public static func calculatePeakLevel(from bufferList: UnsafePointer<AudioBufferList>) -> Float {
        let mutableBufferList = UnsafeMutablePointer(mutating: bufferList)
        let abl = UnsafeMutableAudioBufferListPointer(mutableBufferList)
        var maxPeak: Float = 0.0

        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { continue }

            let floatPtr = data.bindMemory(to: Float.self, capacity: frameCount)
            var peak: Float = 0.0
            vDSP_maxmgv(floatPtr, 1, &peak, vDSP_Length(frameCount))
            if peak > maxPeak {
                maxPeak = peak
            }
        }

        // Clamp between 0.0 and 1.0
        return min(max(maxPeak, 0.0), 1.0)
    }

    /// Scales audio samples in place by the specified volume multiplier, or zeros them if muted.
    public static func processInPlace(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        volume: Float,
        isMuted: Bool
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)

        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { continue }

            let floatPtr = data.bindMemory(to: Float.self, capacity: frameCount)

            if isMuted || volume <= 0.0001 {
                vDSP_vclr(floatPtr, 1, vDSP_Length(frameCount))
            } else if abs(volume - 1.0) > 0.001 {
                var gain = volume
                vDSP_vsmul(floatPtr, 1, &gain, floatPtr, 1, vDSP_Length(frameCount))
            }
        }
    }
}

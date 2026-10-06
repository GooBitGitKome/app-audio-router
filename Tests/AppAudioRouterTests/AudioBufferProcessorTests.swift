import XCTest
import CoreAudio
@testable import AppAudioRouterCore

final class AudioBufferProcessorTests: XCTestCase {
    func testRealtimeAtomicUInt32LoadStoreAndIncrement() {
        let value = RealtimeAtomicUInt32(12)

        XCTAssertEqual(value.load(), 12)
        value.store(34)
        XCTAssertEqual(value.load(), 34)
        XCTAssertEqual(value.increment(), 35)
        XCTAssertEqual(value.load(), 35)
    }

    func testAudioRingBufferWriteAndRead() {
        let ring = AudioRingBuffer(capacityFrames: 1024, channels: 2)
        let inputSamples: [Float] = [0.1, 0.2, 0.3, 0.4] // 2 frames of stereo

        inputSamples.withUnsafeBufferPointer { ptr in
            ring.write(frames: 2, from: ptr.baseAddress!)
        }

        var outputSamples = [Float](repeating: 0.0, count: 4)
        outputSamples.withUnsafeMutableBufferPointer { ptr in
            let readFrames = ring.read(frames: 2, into: ptr.baseAddress!)
            XCTAssertEqual(readFrames, 2)
        }

        XCTAssertEqual(outputSamples[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(outputSamples[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(outputSamples[2], 0.3, accuracy: 0.001)
        XCTAssertEqual(outputSamples[3], 0.4, accuracy: 0.001)
    }

    func testBufferProcessorGainAndMute() {
        let count = 4
        let floatBuffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        floatBuffer.initialize(from: [0.5, -0.5, 0.2, -0.2], count: count)
        defer {
            floatBuffer.deinitialize(count: count)
            floatBuffer.deallocate()
        }

        let audioBuffer = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
            mData: floatBuffer
        )
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: audioBuffer
        )

        // Test Peak Level
        let peak = AudioBufferProcessor.calculatePeakLevel(from: &bufferList)
        XCTAssertEqual(peak, 0.5, accuracy: 0.01)

        // Test Gain (multiply by 2.0)
        AudioBufferProcessor.processInPlace(bufferList: &bufferList, volume: 2.0, isMuted: false)
        XCTAssertEqual(floatBuffer[0], 1.0, accuracy: 0.01)
        XCTAssertEqual(floatBuffer[1], -1.0, accuracy: 0.01)

        // Test Mute
        AudioBufferProcessor.processInPlace(bufferList: &bufferList, volume: 1.0, isMuted: true)
        XCTAssertEqual(floatBuffer[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(floatBuffer[1], 0.0, accuracy: 0.0001)
    }
}

import Foundation
import CoreAudio
import AVFoundation

/// Manages recording audio from the AppAudioRouter Virtual Microphone (or loopback input)
/// and playing it back through the default output device for user self-testing.
public final class VirtualInputTester: NSObject, @unchecked Sendable, AVAudioPlayerDelegate {
    public static let shared = VirtualInputTester()

    public enum TestState: Equatable, Sendable {
        case idle
        case recording(elapsed: TimeInterval, maxDuration: TimeInterval)
        case recorded(duration: TimeInterval, fileURL: URL)
        case playing(elapsed: TimeInterval, duration: TimeInterval)
    }

    private let lock = NSLock()
    private var _state: TestState = .idle
    private var _recordPeakLevel: Float = 0.0
    private var _playbackPeakLevel: Float = 0.0

    public var state: TestState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
    }

    public var recordPeakLevel: Float {
        get { lock.lock(); defer { lock.unlock() }; return _recordPeakLevel }
    }

    public var playbackPeakLevel: Float {
        get { lock.lock(); defer { lock.unlock() }; return _playbackPeakLevel }
    }

    public var onStateChanged: (@Sendable (TestState) -> Void)?
    public var onPeakUpdate: (@Sendable (Float) -> Void)?

    private var ioProcID: AudioDeviceIOProcID?
    private var activeDeviceID: AudioObjectID = 0
    private let ioQueue = DispatchQueue(label: "com.appaudiorouter.tester.input", qos: .userInteractive)

    private var recordedSamples: [Float] = []
    private var recordedSampleRate: Double = 48000.0
    private var recordTimer: DispatchSourceTimer?
    private var recordStartTime: Date?
    private var targetDuration: TimeInterval = 5.0

    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: DispatchSourceTimer?
    private var testAudioFileURL: URL?

    public override init() {
        super.init()
        let tempDir = FileManager.default.temporaryDirectory
        self.testAudioFileURL = tempDir.appendingPathComponent("virtual_input_test.wav")
    }

    deinit {
        stopRecording()
        stopPlayback()
    }

    // MARK: - Target Device Resolution

    /// Locates the Virtual Microphone or underlying loopback device to record from.
    public func resolveTargetDeviceID() -> AudioObjectID? {
        let allDevs = AudioDeviceManager.shared.refreshDevices()

        // 1. AppAudioRouter Virtual Microphone
        if let virtMic = allDevs.first(where: { $0.isInput && $0.name == AggregateDeviceManager.virtualMicDeviceName }) {
            return virtMic.id
        }

        // 2. Underlying loopback device (BlackHole > ZoomAudioDevice > others)
        if let loopback = allDevs.first(where: {
            $0.isInput && (($0.uid.lowercased().contains("blackhole") && !$0.uid.contains("VirtualDesktop")) ||
            $0.uid.contains("zoom.us.zoomaudiodevice"))
        }) {
            return loopback.id
        }

        // 3. Any virtual input device
        return allDevs.first(where: { $0.isVirtual && $0.isInput })?.id
    }

    // MARK: - Recording
 
    /// Starts recording from the Virtual Microphone for the specified duration.
    @discardableResult
    public func startRecording(duration: TimeInterval = 5.0, autoPlayWhenDone: Bool = true) -> Bool {
        internalStopPlayback(notify: false)
        internalStopRecording(notify: false)

        guard let devID = resolveTargetDeviceID() else {
            return false
        }

        let dev = AudioDeviceManager.shared.findDevice(byID: devID)
        let sampleRate = dev?.sampleRate ?? 48000.0

        lock.lock()
        self.activeDeviceID = devID
        self.recordedSamples.removeAll(keepingCapacity: true)
        self.recordedSampleRate = sampleRate
        self.targetDuration = max(1.0, min(duration, 30.0))
        self.recordStartTime = Date()
        self._recordPeakLevel = 0.0
        self._state = .recording(elapsed: 0.0, maxDuration: targetDuration)
        lock.unlock()

        notifyState()

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            devID,
            ioQueue
        ) { [weak self] (_, inInputData, _, _, _) in
            guard let self = self else { return }
            self.handleCapturedBuffer(inInputData)
        }

        guard status == noErr, let validProcID = procID else {
            lock.lock()
            self._state = .idle
            lock.unlock()
            notifyState()
            return false
        }

        let startStatus = AudioDeviceStart(devID, validProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(devID, validProcID)
            lock.lock()
            self._state = .idle
            lock.unlock()
            notifyState()
            return false
        }

        self.ioProcID = validProcID

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.checkRecordProgress(autoPlayWhenDone: autoPlayWhenDone)
        }
        self.recordTimer = timer
        timer.resume()

        return true
    }

    /// Stops active recording and saves the WAV file.
    public func stopRecording(autoPlay: Bool = false) {
        internalStopRecording(notify: true, autoPlay: autoPlay)
    }

    private func internalStopRecording(notify: Bool, autoPlay: Bool = false) {
        recordTimer?.cancel()
        recordTimer = nil

        if let procID = ioProcID, activeDeviceID != 0 {
            AudioDeviceStop(activeDeviceID, procID)
            AudioDeviceDestroyIOProcID(activeDeviceID, procID)
            self.ioProcID = nil
        }

        lock.lock()
        let samples = self.recordedSamples
        let rate = self.recordedSampleRate
        let actualDuration = Double(samples.count) / (rate * 2.0)
        self._recordPeakLevel = 0.0
        lock.unlock()

        guard actualDuration >= 0.2, let fileURL = testAudioFileURL else {
            if notify {
                lock.lock()
                self._state = .idle
                lock.unlock()
                notifyState()
            }
            return
        }

        do {
            try writeWaveFile(to: fileURL, samples: samples, sampleRate: rate, channels: 2)
            lock.lock()
            self._state = .recorded(duration: actualDuration, fileURL: fileURL)
            lock.unlock()
            if notify {
                notifyState()
            }

            if autoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startPlayback()
                }
            }
        } catch {
            if notify {
                lock.lock()
                self._state = .idle
                lock.unlock()
                notifyState()
            }
        }
    }

    private func checkRecordProgress(autoPlayWhenDone: Bool) {
        guard let start = recordStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)

        if elapsed >= targetDuration {
            stopRecording(autoPlay: autoPlayWhenDone)
        } else {
            lock.lock()
            self._state = .recording(elapsed: elapsed, maxDuration: targetDuration)
            lock.unlock()
            notifyState()
        }
    }

    private func handleCapturedBuffer(_ bufferList: UnsafePointer<AudioBufferList>) {
        let peak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)
        lock.lock()
        self._recordPeakLevel = peak
        lock.unlock()
        onPeakUpdate?(peak)

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

        if abl.count == 1 {
            let channelCount = max(1, Int(firstBuf.mNumberChannels))
            let frameCount = Int(firstBuf.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            guard frameCount > 0 else { return }

            let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channelCount)
            if channelCount == 1 {
                // Expand mono to stereo
                var stereo = [Float](repeating: 0, count: frameCount * 2)
                for i in 0..<frameCount {
                    let s = floatPtr[i]
                    stereo[i * 2] = s
                    stereo[i * 2 + 1] = s
                }
                lock.lock()
                recordedSamples.append(contentsOf: stereo)
                lock.unlock()
            } else if channelCount == 2 {
                lock.lock()
                recordedSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: frameCount * 2))
                lock.unlock()
            } else {
                // Multi-channel (> 2): cleanly extract stereo channels 0 and 1
                var stereo = [Float](repeating: 0, count: frameCount * 2)
                for i in 0..<frameCount {
                    stereo[i * 2] = floatPtr[i * channelCount]
                    stereo[i * 2 + 1] = floatPtr[i * channelCount + 1]
                }
                lock.lock()
                recordedSamples.append(contentsOf: stereo)
                lock.unlock()
            }
        } else if abl.count >= 2 {
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let secondRaw = abl[1].mData else { return }
            let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
            let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

            var stereo = [Float](repeating: 0, count: frameCount * 2)
            for i in 0..<frameCount {
                stereo[i * 2] = floatPtrL[i]
                stereo[i * 2 + 1] = floatPtrR[i]
            }
            lock.lock()
            recordedSamples.append(contentsOf: stereo)
            lock.unlock()
        }
    }

    // MARK: - Playback

    /// Plays the recorded test audio through the default system output (speakers/headphones).
    @discardableResult
    public func startPlayback() -> Bool {
        guard let fileURL = testAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        internalStopRecording(notify: false)
        internalStopPlayback(notify: false)

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.isMeteringEnabled = true
            player.volume = 1.0
            player.prepareToPlay()
            guard player.play() else { return false }

            self.audioPlayer = player
            let dur = player.duration

            lock.lock()
            self._state = .playing(elapsed: 0.0, duration: dur)
            lock.unlock()
            notifyState()

            let timer = DispatchSource.makeTimerSource(queue: ioQueue)
            timer.schedule(deadline: .now() + 0.08, repeating: 0.08)
            timer.setEventHandler { [weak self] in
                guard let self = self, let p = self.audioPlayer, p.isPlaying else { return }
                p.updateMeters()
                let avg = p.averagePower(forChannel: 0) // dB in -160...0
                let normalized = max(0.0, min(1.0, (avg + 50.0) / 50.0))

                self.lock.lock()
                self._playbackPeakLevel = normalized
                self._state = .playing(elapsed: p.currentTime, duration: p.duration)
                self.lock.unlock()

                self.onPeakUpdate?(normalized)
                self.notifyState()
            }
            self.playbackTimer = timer
            timer.resume()

            return true
        } catch {
            return false
        }
    }

    /// Stops playback and resets state to .recorded.
    public func stopPlayback() {
        internalStopPlayback(notify: true)
    }

    private func internalStopPlayback(notify: Bool) {
        playbackTimer?.cancel()
        playbackTimer = nil

        if let player = audioPlayer {
            player.stop()
            self.audioPlayer = nil
        }

        lock.lock()
        self._playbackPeakLevel = 0.0
        if case .playing(_, let dur) = _state {
            if let url = testAudioFileURL {
                self._state = .recorded(duration: dur, fileURL: url)
            } else {
                self._state = .idle
            }
        }
        lock.unlock()
        if notify {
            notifyState()
        }
    }

    /// Clears test recording and resets to idle.
    public func reset() {
        internalStopRecording(notify: false)
        internalStopPlayback(notify: false)

        if let fileURL = testAudioFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        lock.lock()
        self.recordedSamples.removeAll()
        self._recordPeakLevel = 0.0
        self._playbackPeakLevel = 0.0
        self._state = .idle
        lock.unlock()
        notifyState()
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopPlayback()
    }

    private func notifyState() {
        let current = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(current)
        }
    }

    // MARK: - WAV Encoder

    private func writeWaveFile(to url: URL, samples: [Float], sampleRate: Double, channels: Int = 2) throws {
        let sampleCount = samples.count
        let bytesPerSample = 2 // 16-bit PCM
        let dataSize = UInt32(sampleCount * bytesPerSample)
        let sampleRateU32 = UInt32(sampleRate)
        let channelsU16 = UInt16(channels)
        let bitsPerSampleU16 = UInt16(16)
        let blockAlign = UInt16(channels * bytesPerSample)
        let byteRate = sampleRateU32 * UInt32(blockAlign)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // "RIFF"
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])

        // "fmt "
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        let subchunk1Size: UInt32 = 16
        withUnsafeBytes(of: subchunk1Size.littleEndian) { data.append(contentsOf: $0) }
        let audioFormatPCM: UInt16 = 1
        withUnsafeBytes(of: audioFormatPCM.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: channelsU16.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRateU32.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSampleU16.littleEndian) { data.append(contentsOf: $0) }

        // "data"
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }

        // 16-bit PCM conversion
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let intSample = Int16(clamped * 32767.0)
            withUnsafeBytes(of: intSample.littleEndian) { data.append(contentsOf: $0) }
        }

        try data.write(to: url, options: .atomic)
    }
}

import Foundation
import CoreAudio

/// Manages per-application audio tapping, buffer routing, gain control, virtual mic dispatch,
/// and live multi-microphone capture & mixing.
public final class AudioRoutingEngine: @unchecked Sendable {
    public static let shared = AudioRoutingEngine()

    public struct ProcessState: Sendable {
        public var volume: Float
        public var isMuted: Bool
        public var targetDeviceUID: String?
        public var routeToMic: Bool
        public var peakLevel: Float

        public init(
            volume: Float = 1.0,
            isMuted: Bool = false,
            targetDeviceUID: String? = nil,
            routeToMic: Bool = false,
            peakLevel: Float = 0.0
        ) {
            self.volume = volume
            self.isMuted = isMuted
            self.targetDeviceUID = targetDeviceUID
            self.routeToMic = routeToMic
            self.peakLevel = peakLevel
        }
    }

    private final class ActiveSession: @unchecked Sendable {
        let processObjectID: AudioObjectID
        let pid: pid_t
        let tap: ProcessTap
        let aggregateDevice: TapAggregateDevice
        let primaryRingBuffer: AudioRingBuffer
        let micRingBuffer: AudioRingBuffer
        let sessionUUID = UUID()
        var state: ProcessState

        init(processObjectID: AudioObjectID, pid: pid_t, tap: ProcessTap, aggregateDevice: TapAggregateDevice) {
            self.processObjectID = processObjectID
            self.pid = pid
            self.tap = tap
            self.aggregateDevice = aggregateDevice
            self.primaryRingBuffer = AudioRingBuffer()
            self.micRingBuffer = AudioRingBuffer()
            self.state = ProcessState()
        }
    }

    private let lock = NSLock()
    private var sessions: [pid_t: ActiveSession] = [:]
    private var renderers: [String: AudioOutputRenderer] = [:] // Key: Device UID
    private var micSources: [String: MicrophoneInputSource] = [:] // Key: Device UID

    // Global desktop tap for "Desktop Audio to Mic"
    private var desktopTapID: AudioObjectID = 0
    private var desktopAggregate: TapAggregateDevice?
    private var desktopMicRingBuffer: AudioRingBuffer?
    public private(set) var isDesktopAudioToMicEnabled: Bool = false
    public private(set) var activeVirtualMicUID: String?

    private var _desktopVolume: Float = 1.0
    private var _isDesktopMuted: Bool = false

    public var desktopVolume: Float {
        get { lock.lock(); defer { lock.unlock() }; return _desktopVolume }
        set { lock.lock(); _desktopVolume = max(0.0, min(newValue, 2.0)); lock.unlock() }
    }

    public var isDesktopMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isDesktopMuted }
        set { lock.lock(); _isDesktopMuted = newValue; lock.unlock() }
    }

    public var onPeakLevelUpdate: (@Sendable (pid_t, Float) -> Void)?
    public var onMicPeakLevelUpdate: (@Sendable (String, Float) -> Void)?
    public var onDesktopPeakLevelUpdate: (@Sendable (Float) -> Void)?

    public init() {
        // Auto-detect a working virtual mic device (like BlackHole or ZoomAudioDevice) if available
        let virtualDevs = AudioDeviceManager.shared.getVirtualDevices()
        let preferred = virtualDevs.first { dev in
            (dev.uid.lowercased().contains("blackhole") && !dev.uid.contains("VirtualDesktop")) || dev.uid.contains("zoom.us.zoomaudiodevice")
        } ?? virtualDevs.first { dev in
            dev.inputChannelCount > 0 && dev.outputChannelCount > 0 && !dev.uid.contains("VirtualDesktop")
        } ?? virtualDevs.first
        self.activeVirtualMicUID = preferred?.uid
    }

    deinit {
        if desktopTapID != 0 {
            desktopAggregate?.stop()
            desktopAggregate?.destroy()
            AudioHardwareDestroyProcessTap(desktopTapID)
            desktopTapID = 0
        }

        lock.lock()
        let activeSources = Array(micSources.values)
        let activeRenderers = Array(renderers.values)
        lock.unlock()

        for source in activeSources {
            source.stop()
        }
        for renderer in activeRenderers {
            renderer.stop()
        }
    }

    public func setActiveVirtualMicUID(_ uid: String) {
        lock.lock()
        let oldUID = activeVirtualMicUID
        activeVirtualMicUID = uid
        let currentMicSources = Array(micSources.values)
        let currentSessions = Array(sessions.values)
        let isDesktopEnabled = isDesktopAudioToMicEnabled
        let desktopRing = desktopMicRingBuffer
        lock.unlock()

        guard oldUID != uid else { return }

        let desktopRendererID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        if let old = oldUID {
            for mic in currentMicSources where mic.routeToVirtualMic {
                renderers[old]?.removeSourceBuffer(id: mic.sourceID)
            }
            for session in currentSessions where session.state.routeToMic {
                renderers[old]?.removeSourceBuffer(id: session.sessionUUID)
            }
            if isDesktopEnabled {
                renderers[old]?.removeSourceBuffer(id: desktopRendererID)
            }
        }
        if let newRenderer = getOrCreateRenderer(deviceUID: uid) {
            for mic in currentMicSources where mic.routeToVirtualMic {
                newRenderer.addSourceBuffer(id: mic.sourceID, buffer: mic.ringBuffer)
            }
            for session in currentSessions where session.state.routeToMic {
                newRenderer.addSourceBuffer(id: session.sessionUUID, buffer: session.micRingBuffer)
            }
            if isDesktopEnabled, let ring = desktopRing {
                newRenderer.addSourceBuffer(id: desktopRendererID, buffer: ring)
            }
        }
    }

    // MARK: - Process Tapping & Routing Control

    /// Starts tapping an application.
    @discardableResult
    public func startTapping(process: AudioProcess, state: ProcessState = ProcessState()) -> Bool {
        lock.lock()
        if let existing = sessions[process.pid] {
            existing.state = state
            lock.unlock()
            updateRoutingForSession(existing)
            return true
        }
        lock.unlock()

        let tap = process.objectIDs.isEmpty
            ? ProcessTap(processObjectID: process.objectID, pid: process.pid)
            : ProcessTap(processObjectIDs: process.objectIDs, pid: process.pid)
        let shouldMuteOriginal = (state.targetDeviceUID != nil) || state.isMuted
        guard tap.create(muteOriginal: shouldMuteOriginal) else {
            return false
        }

        let aggregate = TapAggregateDevice(tapUID: tap.tapUID)
        guard aggregate.create() else {
            tap.destroy()
            return false
        }

        let session = ActiveSession(
            processObjectID: process.objectID,
            pid: process.pid,
            tap: tap,
            aggregateDevice: aggregate
        )
        session.state = state

        // Setup buffer callback
        aggregate.onAudioBuffer = { [weak self, weak session] bufferList in
            guard let self = self, let session = session else { return }
            self.handleCapturedBuffer(session: session, bufferList: bufferList)
        }

        guard aggregate.start() else {
            aggregate.destroy()
            tap.destroy()
            return false
        }

        lock.lock()
        sessions[process.pid] = session
        lock.unlock()

        updateRoutingForSession(session)
        return true
    }

    /// Stops tapping an application.
    public func stopTapping(pid: pid_t) {
        lock.lock()
        guard let session = sessions.removeValue(forKey: pid) else {
            lock.unlock()
            return
        }
        lock.unlock()

        detachSessionFromRenderers(session)
        session.aggregateDevice.stop()
        session.aggregateDevice.destroy()
        session.tap.destroy()
    }

    public func setVolume(pid: pid_t, volume: Float) {
        lock.lock()
        sessions[pid]?.state.volume = max(0.0, min(volume, 2.0))
        lock.unlock()
    }

    public func setMuted(pid: pid_t, isMuted: Bool) {
        lock.lock()
        guard let session = sessions[pid] else {
            lock.unlock()
            return
        }
        session.state.isMuted = isMuted
        let shouldMuteOriginal = (session.state.targetDeviceUID != nil) || isMuted
        lock.unlock()

        session.tap.setMuteOriginal(shouldMuteOriginal)
    }

    public func setTargetDevice(pid: pid_t, deviceUID: String?) {
        lock.lock()
        guard let session = sessions[pid] else {
            lock.unlock()
            return
        }
        session.state.targetDeviceUID = deviceUID
        let shouldMuteOriginal = (deviceUID != nil) || session.state.isMuted
        lock.unlock()

        session.tap.setMuteOriginal(shouldMuteOriginal)
        updateRoutingForSession(session)
    }

    public func setRouteToMic(pid: pid_t, route: Bool) {
        lock.lock()
        guard let session = sessions[pid] else {
            lock.unlock()
            return
        }
        session.state.routeToMic = route
        lock.unlock()

        updateRoutingForSession(session)
    }

    public func getProcessState(pid: pid_t) -> ProcessState? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[pid]?.state
    }

    public func getPeakLevel(pid: pid_t) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return sessions[pid]?.state.peakLevel ?? 0.0
    }

    // MARK: - Desktop Audio to Mic

    public func setDesktopAudioToMic(enabled: Bool, virtualMicDeviceUID: String? = nil) {
        if let uid = virtualMicDeviceUID {
            setActiveVirtualMicUID(uid)
        }

        if !enabled {
            desktopAggregate?.stop()
            desktopAggregate?.destroy()
            if desktopTapID != 0 {
                AudioHardwareDestroyProcessTap(desktopTapID)
                desktopTapID = 0
            }
            if let targetUID = activeVirtualMicUID, desktopMicRingBuffer != nil {
                getOrCreateRenderer(deviceUID: targetUID)?.removeSourceBuffer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            }
            desktopAggregate = nil
            desktopMicRingBuffer = nil
            isDesktopAudioToMicEnabled = false
            onDesktopPeakLevelUpdate?(0.0)
            return
        }

        guard let targetUID = activeVirtualMicUID,
              let targetDevice = AudioDeviceManager.shared.findDevice(byUID: targetUID) else {
            return
        }

        // Clean up any existing desktop tap first
        if desktopTapID != 0 {
            desktopAggregate?.stop()
            desktopAggregate?.destroy()
            AudioHardwareDestroyProcessTap(desktopTapID)
            desktopTapID = 0
        }

        guard let (tapID, tapUID) = ProcessTap.createGlobalTap() else {
            return
        }

        let targetRate = targetDevice.sampleRate > 0 ? targetDevice.sampleRate : 48000.0
        let aggregate = TapAggregateDevice(
            tapUID: tapUID,
            deviceName: "DesktopAudioTapDevice",
            targetSampleRate: targetRate
        )
        guard aggregate.create() else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        let ring = AudioRingBuffer()
        let rendererUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let renderer = getOrCreateRenderer(deviceUID: targetDevice.uid)
        renderer?.addSourceBuffer(id: rendererUUID, buffer: ring)

        aggregate.onAudioBuffer = { [weak self] bufferList in
            guard let self = self else { return }

            // 1. Calculate incoming raw peak level
            let rawPeak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)

            let vol: Float
            let muted: Bool
            self.lock.lock()
            vol = self._desktopVolume
            muted = self._isDesktopMuted
            self.lock.unlock()

            // 2. Report peak level (0 if muted)
            let effectivePeak = muted ? 0.0 : min(1.0, rawPeak * min(vol, 1.0))
            self.onDesktopPeakLevelUpdate?(effectivePeak)

            // If muted or volume is essentially 0, skip writing to virtual mic ring buffer
            if muted || vol <= 0.0001 {
                return
            }

            // 3. Process volume scaling in place
            let mutableBufferList = UnsafeMutablePointer(mutating: bufferList)
            if abs(vol - 1.0) > 0.001 {
                AudioBufferProcessor.processInPlace(
                    bufferList: mutableBufferList,
                    volume: vol,
                    isMuted: false
                )
            }

            let abl = UnsafeMutableAudioBufferListPointer(mutableBufferList)
            guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

            if abl.count == 1 {
                let channels = max(1, Int(firstBuf.mNumberChannels))
                let frameCount = Int(firstBuf.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frameCount > 0 else { return }
                let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channels)
                ring.write(frames: frameCount, from: floatPtr)
            } else if abl.count >= 2 {
                let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
                guard frameCount > 0, let secondRaw = abl[1].mData else { return }
                let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
                let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

                var interleaved = [Float](repeating: 0.0, count: frameCount * 2)
                for i in 0..<frameCount {
                    interleaved[i * 2] = floatPtrL[i]
                    interleaved[i * 2 + 1] = floatPtrR[i]
                }
                interleaved.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    ring.write(frames: frameCount, from: base)
                }
            }
        }

        guard aggregate.start() else {
            aggregate.destroy()
            AudioHardwareDestroyProcessTap(tapID)
            renderer?.removeSourceBuffer(id: rendererUUID)
            return
        }

        self.desktopTapID = tapID
        self.desktopAggregate = aggregate
        self.desktopMicRingBuffer = ring
        self.isDesktopAudioToMicEnabled = true
    }

    // MARK: - Microphone Live Routing & Mixing

    public func setMicrophoneVolume(deviceUID: String, volume: Float) {
        let source = getOrCreateMicSource(deviceUID: deviceUID)
        source?.volume = volume
    }

    public func setMicrophoneMuted(deviceUID: String, isMuted: Bool) {
        let source = getOrCreateMicSource(deviceUID: deviceUID)
        source?.isMuted = isMuted
    }

    public func setMicrophoneRouteToVirtualMic(deviceUID: String, route: Bool) {
        guard let source = getOrCreateMicSource(deviceUID: deviceUID) else { return }
        source.routeToVirtualMic = route

        if route {
            _ = source.start()
            if let micUID = activeVirtualMicUID, let renderer = getOrCreateRenderer(deviceUID: micUID) {
                renderer.addSourceBuffer(id: source.sourceID, buffer: source.ringBuffer)
            }
        } else {
            if let micUID = activeVirtualMicUID {
                renderers[micUID]?.removeSourceBuffer(id: source.sourceID)
            }
        }
    }

    public func getMicrophoneState(deviceUID: String) -> (volume: Float, isMuted: Bool, isRouted: Bool, peakLevel: Float)? {
        lock.lock()
        guard let source = micSources[deviceUID] else {
            lock.unlock()
            return nil
        }
        let vol = source.volume
        let muted = source.isMuted
        let routed = source.routeToVirtualMic
        let peak = source.peakLevel
        lock.unlock()
        return (vol, muted, routed, peak)
    }

    public func getMicrophonePeakLevel(deviceUID: String) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return micSources[deviceUID]?.peakLevel ?? 0.0
    }

    public func stopMicrophone(deviceUID: String) {
        lock.lock()
        guard let source = micSources.removeValue(forKey: deviceUID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let micUID = activeVirtualMicUID {
            renderers[micUID]?.removeSourceBuffer(id: source.sourceID)
        }
        source.stop()
    }

    private func getOrCreateMicSource(deviceUID: String) -> MicrophoneInputSource? {
        lock.lock()
        if let existing = micSources[deviceUID] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let device = AudioDeviceManager.shared.findDevice(byUID: deviceUID),
              device.isInput else {
            return nil
        }

        let source = MicrophoneInputSource(deviceID: device.id, deviceUID: device.uid)
        source.onPeakLevelUpdate = { [weak self] peak in
            self?.onMicPeakLevelUpdate?(deviceUID, peak)
        }
        _ = source.start()

        lock.lock()
        micSources[deviceUID] = source
        lock.unlock()
        return source
    }

    // MARK: - Buffer Handling & DSP

    private func handleCapturedBuffer(session: ActiveSession, bufferList: UnsafePointer<AudioBufferList>) {
        let peak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)
        session.state.peakLevel = peak
        onPeakLevelUpdate?(session.pid, peak)

        let mutableBufferList = UnsafeMutablePointer(mutating: bufferList)
        AudioBufferProcessor.processInPlace(
            bufferList: mutableBufferList,
            volume: session.state.volume,
            isMuted: session.state.isMuted
        )

        let abl = UnsafeMutableAudioBufferListPointer(mutableBufferList)
        guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

        if abl.count == 1 {
            let channels = max(1, Int(firstBuf.mNumberChannels))
            let frameCount = Int(firstBuf.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frameCount > 0 else { return }
            let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channels)

            if session.state.targetDeviceUID != nil {
                session.primaryRingBuffer.write(frames: frameCount, from: floatPtr)
            }
            if session.state.routeToMic {
                session.micRingBuffer.write(frames: frameCount, from: floatPtr)
            }
        } else if abl.count >= 2 {
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let secondRaw = abl[1].mData else { return }
            let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
            let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

            var interleaved = [Float](repeating: 0.0, count: frameCount * 2)
            for i in 0..<frameCount {
                interleaved[i * 2] = floatPtrL[i]
                interleaved[i * 2 + 1] = floatPtrR[i]
            }
            interleaved.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                if session.state.targetDeviceUID != nil {
                    session.primaryRingBuffer.write(frames: frameCount, from: base)
                }
                if session.state.routeToMic {
                    session.micRingBuffer.write(frames: frameCount, from: base)
                }
            }
        }
    }

    // MARK: - Renderer Assignment

    private func updateRoutingForSession(_ session: ActiveSession) {
        // Target Output Device
        if let targetUID = session.state.targetDeviceUID {
            if let renderer = getOrCreateRenderer(deviceUID: targetUID) {
                renderer.addSourceBuffer(id: session.sessionUUID, buffer: session.primaryRingBuffer)
            }
        } else {
            // Remove from any previous target renderer
            for renderer in renderers.values {
                renderer.removeSourceBuffer(id: session.sessionUUID)
            }
        }

        // Virtual Mic Device
        if session.state.routeToMic, let micUID = activeVirtualMicUID {
            if let micRenderer = getOrCreateRenderer(deviceUID: micUID) {
                micRenderer.addSourceBuffer(id: session.sessionUUID, buffer: session.micRingBuffer)
            }
        } else if let micUID = activeVirtualMicUID {
            renderers[micUID]?.removeSourceBuffer(id: session.sessionUUID)
        }
    }

    private func detachSessionFromRenderers(_ session: ActiveSession) {
        lock.lock()
        let activeRenderers = Array(renderers.values)
        lock.unlock()

        for renderer in activeRenderers {
            renderer.removeSourceBuffer(id: session.sessionUUID)
        }
    }

    private func getOrCreateRenderer(deviceUID: String) -> AudioOutputRenderer? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = renderers[deviceUID] {
            return existing
        }

        guard let device = AudioDeviceManager.shared.findDevice(byUID: deviceUID) else {
            return nil
        }

        let renderer = AudioOutputRenderer(deviceID: device.id, deviceUID: device.uid)
        renderers[deviceUID] = renderer
        return renderer
    }
}

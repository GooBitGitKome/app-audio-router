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
        let scratchCapacitySamples = 32_768
        let interleavedScratch: UnsafeMutablePointer<Float>
        let volumeValue = RealtimeAtomicUInt32(Float(1.0).bitPattern)
        let mutedValue = RealtimeAtomicUInt32(0)
        let routeToMicValue = RealtimeAtomicUInt32(0)
        let hasTargetValue = RealtimeAtomicUInt32(0)
        let peakValue = RealtimeAtomicUInt32(0)
        var state: ProcessState

        init(processObjectID: AudioObjectID, pid: pid_t, tap: ProcessTap, aggregateDevice: TapAggregateDevice) {
            self.processObjectID = processObjectID
            self.pid = pid
            self.tap = tap
            self.aggregateDevice = aggregateDevice
            self.primaryRingBuffer = AudioRingBuffer()
            self.micRingBuffer = AudioRingBuffer()
            self.state = ProcessState()
            self.interleavedScratch = .allocate(capacity: scratchCapacitySamples)
        }

        deinit {
            interleavedScratch.deallocate()
        }

        func apply(_ newState: ProcessState) {
            state = newState
            volumeValue.store(newState.volume.bitPattern)
            mutedValue.store(newState.isMuted ? 1 : 0)
            routeToMicValue.store(newState.routeToMic ? 1 : 0)
            hasTargetValue.store(newState.targetDeviceUID == nil ? 0 : 1)
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
    private let desktopInterleavedScratch = UnsafeMutablePointer<Float>.allocate(capacity: 32_768)
    private let desktopPeakBits = RealtimeAtomicUInt32(0)
    private let desktopVolumeBits = RealtimeAtomicUInt32(Float(1.0).bitPattern)
    private let desktopMutedFlag = RealtimeAtomicUInt32(0)
    private let desktopMeterQueue = DispatchQueue(label: "com.appaudiorouter.desktop.meter", qos: .utility)
    private var desktopMeterTimer: DispatchSourceTimer?
    private let processMeterQueue = DispatchQueue(label: "com.appaudiorouter.process.meter", qos: .utility)
    private var processMeterTimer: DispatchSourceTimer?
    public private(set) var isDesktopAudioToMicEnabled: Bool = false
    public private(set) var activeVirtualMicUID: String?
    public private(set) var desktopTapExcludedBundleIDs: Set<String> = []
    public private(set) var unresolvedDesktopTapExcludedBundleIDs: Set<String> = []

    public var desktopVolume: Float {
        get { Float(bitPattern: desktopVolumeBits.load()) }
        set { desktopVolumeBits.store(max(0.0, min(newValue, 2.0)).bitPattern) }
    }

    public var isDesktopMuted: Bool {
        get { desktopMutedFlag.load() != 0 }
        set { desktopMutedFlag.store(newValue ? 1 : 0) }
    }

    public var onPeakLevelUpdate: (@Sendable (pid_t, Float) -> Void)?
    public var onMicPeakLevelUpdate: (@Sendable (String, Float) -> Void)?
    public var onDesktopPeakLevelUpdate: (@Sendable (Float) -> Void)?

    public init() {
        // Auto-detect a working virtual mic device (like BlackHole or ZoomAudioDevice) if available
        let virtualDevs = AudioDeviceManager.shared.getVirtualDevices()
        let preferred = virtualDevs.first { dev in
            dev.isInput && dev.isOutput && !dev.isAggregate &&
            ((dev.uid.lowercased().contains("blackhole") && !dev.uid.contains("VirtualDesktop")) || dev.uid.contains("zoom.us.zoomaudiodevice"))
        } ?? virtualDevs.first { dev in
            dev.isInput && dev.isOutput && !dev.isAggregate && !dev.uid.contains("VirtualDesktop")
        }
        self.activeVirtualMicUID = preferred?.uid
    }

    deinit {
        desktopMeterTimer?.cancel()
        processMeterTimer?.cancel()
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
        desktopInterleavedScratch.deallocate()
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
            existing.apply(state)
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
        session.apply(state)

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
        startProcessMeterTimer()

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
        lock.lock()
        let hasSessions = !sessions.isEmpty
        lock.unlock()
        if !hasSessions {
            processMeterTimer?.cancel()
            processMeterTimer = nil
        }
    }

    public func setVolume(pid: pid_t, volume: Float) {
        lock.lock()
        if let session = sessions[pid] {
            let clamped = max(0.0, min(volume, 2.0))
            session.state.volume = clamped
            session.volumeValue.store(clamped.bitPattern)
        }
        lock.unlock()
    }

    public func setMuted(pid: pid_t, isMuted: Bool) {
        lock.lock()
        guard let session = sessions[pid] else {
            lock.unlock()
            return
        }
        session.state.isMuted = isMuted
        session.mutedValue.store(isMuted ? 1 : 0)
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
        session.hasTargetValue.store(deviceUID == nil ? 0 : 1)
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
        session.routeToMicValue.store(route ? 1 : 0)
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

    /// Sets app-level global tap exclusions. Active routes are restarted so the new exclusion
    /// list takes effect immediately; the tap still always excludes AppAudioRouter itself.
    public func setDesktopTapExcludedBundleIDs(_ bundleIDs: Set<String>) {
        lock.lock()
        guard bundleIDs != desktopTapExcludedBundleIDs else {
            lock.unlock()
            return
        }
        desktopTapExcludedBundleIDs = bundleIDs
        let shouldRestart = isDesktopAudioToMicEnabled
        let targetUID = activeVirtualMicUID
        lock.unlock()

        if shouldRestart {
            setDesktopAudioToMic(enabled: false)
            setDesktopAudioToMic(enabled: true, virtualMicDeviceUID: targetUID)
        }
    }

    public func setDesktopAudioToMic(enabled: Bool, virtualMicDeviceUID: String? = nil) {
        if let uid = virtualMicDeviceUID {
            setActiveVirtualMicUID(uid)
        }

        if !enabled {
            desktopMeterTimer?.cancel()
            desktopMeterTimer = nil
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
            desktopPeakBits.store(0)
            onDesktopPeakLevelUpdate?(0.0)
            return
        }

        // A failed restart must not leave the engine reporting an old active route.
        isDesktopAudioToMicEnabled = false

        guard let targetUID = activeVirtualMicUID,
              let targetDevice = AudioDeviceManager.shared.findDevice(byUID: targetUID),
              targetDevice.isOutput else {
            return
        }

        // Clean up any existing desktop tap first
        if desktopTapID != 0 {
            if let targetUID = activeVirtualMicUID {
                getOrCreateRenderer(deviceUID: targetUID)?.removeSourceBuffer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                )
            }
            desktopAggregate?.stop()
            desktopAggregate?.destroy()
            AudioHardwareDestroyProcessTap(desktopTapID)
            desktopTapID = 0
            desktopAggregate = nil
            desktopMicRingBuffer = nil
        }

        lock.lock()
        let excludedBundleIDs = desktopTapExcludedBundleIDs
        lock.unlock()
        let processes = AudioProcessManager.shared.refreshProcesses()
        let excludedProcessIDs = ProcessTap.processObjectIDs(
            forBundleIdentifiers: excludedBundleIDs,
            processes: processes
        )
        let resolvedBundleIDs = Set(processes.compactMap { process -> String? in
            guard let bundleID = process.bundleIdentifier,
                  !process.objectIDs.isEmpty,
                  excludedBundleIDs.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) else { return nil }
            return excludedBundleIDs.first(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") })
        })
        lock.lock()
        unresolvedDesktopTapExcludedBundleIDs = excludedBundleIDs.subtracting(resolvedBundleIDs)
        lock.unlock()
        guard let (tapID, tapUID) = ProcessTap.createGlobalTap(excludeProcesses: excludedProcessIDs) else {
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
        guard let renderer = getOrCreateRenderer(deviceUID: targetDevice.uid) else {
            aggregate.destroy()
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        renderer.addSourceBuffer(id: rendererUUID, buffer: ring)
        guard renderer.isRunning else {
            renderer.removeSourceBuffer(id: rendererUUID)
            aggregate.destroy()
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        aggregate.onAudioBuffer = { [weak self] bufferList in
            guard let self = self else { return }

            // 1. Calculate incoming raw peak level
            let rawPeak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)

            let vol = Float(bitPattern: self.desktopVolumeBits.load())
            let muted = self.desktopMutedFlag.load() != 0

            // 2. Report peak level (0 if muted)
            let effectivePeak = muted ? 0.0 : min(1.0, rawPeak * min(vol, 1.0))
            self.desktopPeakBits.store(effectivePeak.bitPattern)

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
                guard frameCount > 0, frameCount * channels <= 32_768 else { return }
                let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channels)
                ring.write(frames: frameCount, from: floatPtr)
            } else if abl.count >= 2 {
                let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
                guard frameCount > 0, frameCount * 2 <= 32_768, let secondRaw = abl[1].mData else { return }
                let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
                let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

                for i in 0..<frameCount {
                    self.desktopInterleavedScratch[i * 2] = floatPtrL[i]
                    self.desktopInterleavedScratch[i * 2 + 1] = floatPtrR[i]
                }
                ring.write(frames: frameCount, from: self.desktopInterleavedScratch)
            }
        }

        guard aggregate.start() else {
            aggregate.destroy()
            AudioHardwareDestroyProcessTap(tapID)
            renderer.removeSourceBuffer(id: rendererUUID)
            return
        }

        self.desktopTapID = tapID
        self.desktopAggregate = aggregate
        self.desktopMicRingBuffer = ring
        self.isDesktopAudioToMicEnabled = true
        startDesktopMeterTimer()
    }

    private func startDesktopMeterTimer() {
        desktopMeterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: desktopMeterQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.onDesktopPeakLevelUpdate?(Float(bitPattern: self.desktopPeakBits.load()))
        }
        desktopMeterTimer = timer
        timer.resume()
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

    private func startProcessMeterTimer() {
        guard processMeterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: processMeterQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let sessions = Array(self.sessions.values)
            let updates = sessions.map { session -> (pid_t, Float) in
                let peak = Float(bitPattern: session.peakValue.load())
                session.state.peakLevel = peak
                return (session.pid, peak)
            }
            self.lock.unlock()
            for (pid, peak) in updates {
                self.onPeakLevelUpdate?(pid, peak)
            }
        }
        processMeterTimer = timer
        timer.resume()
    }

    private func handleCapturedBuffer(session: ActiveSession, bufferList: UnsafePointer<AudioBufferList>) {
        let peak = AudioBufferProcessor.calculatePeakLevel(from: bufferList)
        session.peakValue.store(peak.bitPattern)

        let mutableBufferList = UnsafeMutablePointer(mutating: bufferList)
        AudioBufferProcessor.processInPlace(
            bufferList: mutableBufferList,
            volume: Float(bitPattern: session.volumeValue.load()),
            isMuted: session.mutedValue.load() != 0
        )

        let hasTarget = session.hasTargetValue.load() != 0
        let routeToMic = session.routeToMicValue.load() != 0
        guard hasTarget || routeToMic else { return }

        let abl = UnsafeMutableAudioBufferListPointer(mutableBufferList)
        guard let firstBuf = abl.first, let firstRaw = firstBuf.mData else { return }

        if abl.count == 1 {
            let channels = max(1, Int(firstBuf.mNumberChannels))
            let frameCount = Int(firstBuf.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frameCount > 0 else { return }
            let floatPtr = firstRaw.bindMemory(to: Float.self, capacity: frameCount * channels)

            if hasTarget {
                session.primaryRingBuffer.write(frames: frameCount, from: floatPtr)
            }
            if routeToMic {
                session.micRingBuffer.write(frames: frameCount, from: floatPtr)
            }
        } else if abl.count >= 2 {
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, frameCount * 2 <= session.scratchCapacitySamples,
                  let secondRaw = abl[1].mData else { return }
            let floatPtrL = firstRaw.bindMemory(to: Float.self, capacity: frameCount)
            let floatPtrR = secondRaw.bindMemory(to: Float.self, capacity: frameCount)

            for i in 0..<frameCount {
                session.interleavedScratch[i * 2] = floatPtrL[i]
                session.interleavedScratch[i * 2 + 1] = floatPtrR[i]
            }
            if hasTarget {
                session.primaryRingBuffer.write(frames: frameCount, from: session.interleavedScratch)
            }
            if routeToMic {
                session.micRingBuffer.write(frames: frameCount, from: session.interleavedScratch)
            }
        }
    }

    // MARK: - Renderer Assignment

    private func updateRoutingForSession(_ session: ActiveSession) {
        // Remove obsolete consumers before attaching the new destination. A ring
        // has one read cursor and cannot be shared between output renderers.
        lock.lock()
        let obsoleteRenderers = renderers.filter { $0.key != session.state.targetDeviceUID }.map(\.value)
        lock.unlock()
        for renderer in obsoleteRenderers {
            renderer.removeSourceBuffer(id: session.sessionUUID)
        }

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

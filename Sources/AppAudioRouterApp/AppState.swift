import Foundation
import CoreAudio
import AppKit
import Observation
import AppAudioRouterCore

@Observable
public final class AppState: @unchecked Sendable {
    public static let shared = AppState()

    public var devices: [AudioDevice] = []
    public var processes: [AudioProcess] = []
    public var showAllProcesses: Bool = false
    public private(set) var excludedDesktopAudioBundleIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "desktopTapExcludedBundleIDs") ?? []
    )

    public var desktopAudioExclusionCandidates: [AudioProcess] {
        var seen = Set<String>()
        return processes.filter { process in
            guard let bundleID = process.bundleIdentifier,
                  !bundleID.isEmpty,
                  !process.isSystemDaemon,
                  process.pid != ProcessInfo.processInfo.processIdentifier,
                  seen.insert(bundleID).inserted else { return false }
            return true
        }
    }

    public var defaultOutputDevice: AudioDevice? {
        devices.first { $0.isDefaultOutput }
    }
    public var defaultInputDevice: AudioDevice? {
        devices.first { $0.isDefaultInput }
    }
    public var virtualDevices: [AudioDevice] {
        devices.filter { $0.isVirtual && $0.isInput }
    }
    public var outputDevices: [AudioDevice] {
        devices.filter { $0.isOutput }
    }
    public var inputDevices: [AudioDevice] {
        devices.filter { $0.isInput }
    }

    /// Visible output devices for Master Output (excludes internal third-party virtual devices)
    public var visibleOutputDevices: [AudioDevice] {
        devices.filter { $0.isOutput && (!$0.isVirtual || $0.isAggregate) }
    }

    /// Visible input devices for Master Input (physical inputs plus AppAudioRouter's own virtual microphone)
    public var visibleInputDevices: [AudioDevice] {
        devices.filter { $0.isInput && (!$0.isVirtual || isAppVirtualMic(device: $0)) }
    }

    /// Pure physical microphones (MacBook Pro mic, USB mic, headset mic).
    /// Third-party virtual mics (Zoom, Teams, Virtual Desktop, BlackHole) are strictly hidden.
    public var physicalInputDevices: [AudioDevice] {
        devices.filter { $0.isInput && !$0.isVirtual && !$0.isAggregate }
    }

    public var appVirtualMicDevice: AudioDevice? {
        devices.first { $0.isInput && isAppVirtualMic(device: $0) }
    }

    public var isVirtualMicReady: Bool {
        appVirtualMicDevice != nil
    }

    public var hasVirtualLoopbackEngine: Bool = true

    // Backward compatibility aliases
    public var desktopInputMicDevice: AudioDevice? { appVirtualMicDevice }
    public var isDesktopInputMicReady: Bool { isVirtualMicReady }

    private func isAppVirtualMic(device: AudioDevice) -> Bool {
        return device.name == AggregateDeviceManager.virtualMicDeviceName ||
               device.name == "Desktop Input Microphone" ||
               device.uid.contains("com.appaudiorouter.virtualmic") ||
               device.uid.contains("com.appaudiorouter.aggregatemic")
    }

    // Per-Application State
    public var appVolumes: [pid_t: Float] = [:]
    public var appMutes: [pid_t: Bool] = [:]
    public var appTargetDevices: [pid_t: String] = [:]
    public var appMicRoutes: [pid_t: Bool] = [:]
    public var appPeakLevels: [pid_t: Float] = [:]

    // Per-Microphone State
    public var micVolumes: [String: Float] = [:]
    public var micMutes: [String: Bool] = [:]
    public var micRoutes: [String: Bool] = [:]
    public var micPeakLevels: [String: Float] = [:]

    // Desktop Audio State
    public var isDesktopToMicEnabled: Bool = false
    public var desktopPeakLevel: Float = 0.0
    public var desktopVolume: Float = 1.0
    public var isDesktopMuted: Bool = false
    public var isDesktopMeterEnabled: Bool = true
    public var unresolvedDesktopTapExcludedBundleIDs: Set<String> = []

    // Virtual Input Test State
    public var testState: VirtualInputTester.TestState = .idle
    public var testPeakLevel: Float = 0.0

    public var selectedVirtualMicUID: String = "" {
        didSet {
            guard selectedVirtualMicUID != oldValue, !selectedVirtualMicUID.isEmpty else { return }
            routingEngine.setActiveVirtualMicUID(selectedVirtualMicUID)
        }
    }

    private let deviceManager = AudioDeviceManager.shared
    private let processManager = AudioProcessManager.shared
    private let routingEngine = AudioRoutingEngine.shared
    private var refreshTimer: Timer?
    private var appActiveObserver: NSObjectProtocol?

    public init() {
        refresh()
        setupListeners()
        setupPolling()
        routingEngine.setDesktopTapExcludedBundleIDs(excludedDesktopAudioBundleIDs)
    }

    deinit {
        refreshTimer?.invalidate()
        if let obs = appActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public func refresh() {
        self.devices = deviceManager.refreshDevices()
        self.processes = processManager.refreshProcesses()

        if selectedVirtualMicUID.isEmpty {
            let preferred = virtualDevices.first { dev in
                dev.isInput && dev.isOutput && !dev.isAggregate &&
                ((dev.uid.lowercased().contains("blackhole") && !dev.uid.contains("VirtualDesktop")) || dev.uid.contains("zoom.us.zoomaudiodevice"))
            } ?? virtualDevices.first { dev in
                dev.isInput && dev.isOutput && !dev.isAggregate && !dev.uid.contains("VirtualDesktop")
            }
            if let target = preferred {
                selectedVirtualMicUID = target.uid
                routingEngine.setActiveVirtualMicUID(target.uid)
            }
        }
    }

    private func setupPolling() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    private func setupListeners() {
        deviceManager.onDevicesChanged = { [weak self] newDevices in
            Task { @MainActor in
                self?.devices = newDevices
            }
        }

        routingEngine.onPeakLevelUpdate = { [weak self] pid, peak in
            Task { @MainActor in
                self?.appPeakLevels[pid] = peak
            }
        }

        routingEngine.onMicPeakLevelUpdate = { [weak self] uid, peak in
            Task { @MainActor in
                self?.micPeakLevels[uid] = peak
            }
        }

        routingEngine.onDesktopPeakLevelUpdate = { [weak self] peak in
            Task { @MainActor in
                guard let self = self else { return }
                self.desktopPeakLevel = self.isDesktopMeterEnabled ? peak : 0.0
            }
        }

        VirtualInputTester.shared.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.testState = newState
            }
        }

        VirtualInputTester.shared.onPeakUpdate = { [weak self] peak in
            Task { @MainActor in
                self?.testPeakLevel = peak
            }
        }
    }

    // MARK: - App Controls

    public func volume(for pid: pid_t) -> Float {
        appVolumes[pid] ?? 1.0
    }

    public func isMuted(for pid: pid_t) -> Bool {
        appMutes[pid] ?? false
    }

    public func targetDevice(for pid: pid_t) -> String {
        appTargetDevices[pid] ?? "default"
    }

    public func isMicRouted(for pid: pid_t) -> Bool {
        appMicRoutes[pid] ?? false
    }

    public func peakLevel(for pid: pid_t) -> Float {
        appPeakLevels[pid] ?? 0.0
    }

    public func setVolume(for proc: AudioProcess, volume: Float) {
        appVolumes[proc.pid] = volume
        let currentProc = processes.first { $0.pid == proc.pid } ?? proc
        if currentProc.objectID != 0 {
            ensureTapping(process: currentProc)
            routingEngine.setVolume(pid: currentProc.pid, volume: volume)
        }
    }

    public func toggleMute(for proc: AudioProcess) {
        let current = isMuted(for: proc.pid)
        let newMuted = !current
        appMutes[proc.pid] = newMuted
        let currentProc = processes.first { $0.pid == proc.pid } ?? proc
        if currentProc.objectID != 0 {
            ensureTapping(process: currentProc)
            routingEngine.setMuted(pid: currentProc.pid, isMuted: newMuted)
        }
    }

    public func setTargetDevice(for proc: AudioProcess, deviceUID: String) {
        appTargetDevices[proc.pid] = deviceUID
        let currentProc = processes.first { $0.pid == proc.pid } ?? proc
        if currentProc.objectID != 0 {
            ensureTapping(process: currentProc)
            let actualUID = (deviceUID == "default") ? nil : deviceUID
            routingEngine.setTargetDevice(pid: currentProc.pid, deviceUID: actualUID)
        }
    }

    public func toggleMicRoute(for proc: AudioProcess) {
        let current = isMicRouted(for: proc.pid)
        let newRoute = !current
        appMicRoutes[proc.pid] = newRoute
        let currentProc = processes.first { $0.pid == proc.pid } ?? proc
        if currentProc.objectID != 0 {
            ensureTapping(process: currentProc)
            routingEngine.setRouteToMic(pid: currentProc.pid, route: newRoute)
        }
    }

    // MARK: - Microphone Controls

    public func volume(forMic uid: String) -> Float {
        micVolumes[uid] ?? 1.0
    }

    public func isMuted(forMic uid: String) -> Bool {
        micMutes[uid] ?? false
    }

    public func isMicRouted(forMic uid: String) -> Bool {
        micRoutes[uid] ?? false
    }

    public func peakLevel(forMic uid: String) -> Float {
        micPeakLevels[uid] ?? 0.0
    }

    public func setMicVolume(device: AudioDevice, volume: Float) {
        micVolumes[device.uid] = volume
        routingEngine.setMicrophoneVolume(deviceUID: device.uid, volume: volume)
    }

    public func toggleMicMute(device: AudioDevice) {
        let current = isMuted(forMic: device.uid)
        let newMuted = !current
        micMutes[device.uid] = newMuted
        routingEngine.setMicrophoneMuted(deviceUID: device.uid, isMuted: newMuted)
    }

    public func toggleMicRoute(device: AudioDevice) {
        let current = isMicRouted(forMic: device.uid)
        let newRoute = !current
        micRoutes[device.uid] = newRoute
        routingEngine.setMicrophoneRouteToVirtualMic(deviceUID: device.uid, route: newRoute)
    }

    // MARK: - Global Routing & Virtual Microphone

    public func toggleDesktopToMic() {
        let shouldEnable = !isDesktopToMicEnabled
        if shouldEnable && !isVirtualMicReady {
            _ = setupAppVirtualMicrophone(setAsDefault: false)
        }
        routingEngine.setDesktopAudioToMic(
            enabled: shouldEnable,
            virtualMicDeviceUID: selectedVirtualMicUID.isEmpty ? nil : selectedVirtualMicUID
        )
        isDesktopToMicEnabled = routingEngine.isDesktopAudioToMicEnabled
        unresolvedDesktopTapExcludedBundleIDs = routingEngine.unresolvedDesktopTapExcludedBundleIDs
        if !isDesktopToMicEnabled {
            desktopPeakLevel = 0.0
        }
    }

    public func setDesktopAudioExcluded(bundleIdentifier: String, excluded: Bool) {
        if excluded {
            excludedDesktopAudioBundleIDs.insert(bundleIdentifier)
        } else {
            excludedDesktopAudioBundleIDs.remove(bundleIdentifier)
        }
        UserDefaults.standard.set(Array(excludedDesktopAudioBundleIDs).sorted(), forKey: "desktopTapExcludedBundleIDs")
        routingEngine.setDesktopTapExcludedBundleIDs(excludedDesktopAudioBundleIDs)
        isDesktopToMicEnabled = routingEngine.isDesktopAudioToMicEnabled
        unresolvedDesktopTapExcludedBundleIDs = routingEngine.unresolvedDesktopTapExcludedBundleIDs
    }

    public func setDesktopVolume(_ volume: Float) {
        desktopVolume = max(0.0, min(volume, 2.0))
        routingEngine.desktopVolume = desktopVolume
    }

    public func toggleDesktopMute() {
        isDesktopMuted.toggle()
        routingEngine.isDesktopMuted = isDesktopMuted
    }

    public func toggleDesktopMeter() {
        isDesktopMeterEnabled.toggle()
        if !isDesktopMeterEnabled {
            desktopPeakLevel = 0.0
        }
    }

    private var isSettingUpVirtualMic = false

    /// Automatically sets up the ephemeral AppAudioRouter Virtual Microphone.
    /// Operates silently without displaying third-party virtual drivers to the user.
    @discardableResult
    public func setupAppVirtualMicrophone(setAsDefault: Bool = false) -> AudioObjectID? {
        guard !isSettingUpVirtualMic else { return nil }
        isSettingUpVirtualMic = true
        defer { isSettingUpVirtualMic = false }

        let allDevs = deviceManager.refreshDevices()

        // Locate internal loopback sub-device (BlackHole > ZoomAudioDevice > others)
        let loopback = allDevs.first { dev in
            dev.isInput && dev.isOutput && !dev.isAggregate &&
            dev.uid.lowercased().contains("blackhole") && !dev.uid.contains("VirtualDesktop")
        } ?? allDevs.first { dev in
            dev.isInput && dev.isOutput && !dev.isAggregate && dev.uid.contains("zoom.us.zoomaudiodevice")
        } ?? allDevs.first { dev in
            dev.isVirtual && dev.isInput && dev.isOutput && !dev.isAggregate && !dev.uid.contains("VirtualDesktop")
        }

        guard let target = loopback else {
            hasVirtualLoopbackEngine = false
            return nil
        }

        hasVirtualLoopbackEngine = true
        if self.selectedVirtualMicUID != target.uid {
            self.selectedVirtualMicUID = target.uid
        }
        routingEngine.setActiveVirtualMicUID(target.uid)

        let newID = AggregateDeviceManager.shared.createVirtualMicrophone(subDeviceUID: target.uid)
        refresh()

        if let id = newID, setAsDefault {
            setDefaultInput(id: id)
        }
        return newID
    }

    /// Cleans up and destroys the ephemeral virtual microphone when AppAudioRouter terminates.
    public func cleanupAppVirtualMicrophone() {
        VirtualInputTester.shared.reset()
        AggregateDeviceManager.shared.destroyVirtualMicrophone()
        refresh()
    }

    // MARK: - Virtual Input Test Controls

    public func startVirtualInputTest(duration: TimeInterval = 5.0, autoPlay: Bool = true) {
        if !isDesktopToMicEnabled {
            toggleDesktopToMic()
        }
        VirtualInputTester.shared.startRecording(duration: duration, autoPlayWhenDone: autoPlay)
    }

    public func stopVirtualInputRecording() {
        VirtualInputTester.shared.stopRecording(autoPlay: true)
    }

    public func startVirtualInputPlayback() {
        VirtualInputTester.shared.startPlayback()
    }

    public func stopVirtualInputPlayback() {
        VirtualInputTester.shared.stopPlayback()
    }

    public func resetVirtualInputTest() {
        VirtualInputTester.shared.reset()
    }

    public func setAppVirtualMicAsDefault() {
        if let mic = appVirtualMicDevice {
            setDefaultInput(id: mic.id)
        } else if let newID = setupAppVirtualMicrophone(setAsDefault: true) {
            setDefaultInput(id: newID)
        }
    }

    /// Helper to restart coreaudiod with user authorization if standalone drivers need reloading.
    public func restartCoreAudioEngine() {
        let script = "do shell script \"launchctl kickstart -kp system/com.apple.audio.coreaudiod\" with administrator privileges"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.refresh()
                _ = self?.setupAppVirtualMicrophone()
            }
        }
    }

    // Backward compatibility aliases
    @discardableResult
    public func setupDesktopInputMicrophone(setAsDefault: Bool = false, forceRecreate: Bool = false) -> AudioObjectID? {
        return setupAppVirtualMicrophone(setAsDefault: setAsDefault)
    }

    public func setDesktopInputMicAsDefault() {
        setAppVirtualMicAsDefault()
    }

    public func setDefaultOutput(id: AudioObjectID) {
        _ = deviceManager.setDefaultOutputDevice(id: id)
    }

    public func setDefaultInput(id: AudioObjectID) {
        _ = deviceManager.setDefaultInputDevice(id: id)
    }

    public func setVirtualMicAsDefaultInput() {
        if let desktopMic = desktopInputMicDevice {
            setDefaultInput(id: desktopMic.id)
            return
        }
        guard let virtDev = virtualDevices.first(where: { $0.uid == selectedVirtualMicUID }) ?? virtualDevices.first else {
            return
        }
        setDefaultInput(id: virtDev.id)
    }

    public func createMultiOutput(name: String, uids: [String]) {
        _ = AggregateDeviceManager.shared.createMultiOutputDevice(
            name: name,
            subDeviceUIDs: uids,
            isPrivate: false
        )
        refresh()
    }

    @discardableResult
    public func createAggregateInput(name: String, uids: [String], setAsDefault: Bool = false) -> AudioObjectID? {
        let newID = AggregateDeviceManager.shared.createAggregateInputDevice(
            name: name,
            subDeviceUIDs: uids,
            isPrivate: false
        )
        refresh()
        if setAsDefault, let id = newID {
            setDefaultInput(id: id)
        }
        return newID
    }

    private func ensureTapping(process: AudioProcess) {
        let currentProc = processes.first { $0.pid == process.pid } ?? process
        guard currentProc.objectID != 0 else { return }
        if routingEngine.getProcessState(pid: currentProc.pid) == nil {
            let state = AudioRoutingEngine.ProcessState(
                volume: appVolumes[currentProc.pid] ?? 1.0,
                isMuted: appMutes[currentProc.pid] ?? false,
                targetDeviceUID: (appTargetDevices[currentProc.pid] == "default") ? nil : appTargetDevices[currentProc.pid],
                routeToMic: appMicRoutes[currentProc.pid] ?? false
            )
            routingEngine.startTapping(process: currentProc, state: state)
        }
    }
}

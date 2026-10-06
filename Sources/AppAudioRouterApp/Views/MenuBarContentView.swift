import SwiftUI
import AppKit
import AppAudioRouterCore

/// Main popover view displayed from the macOS menu bar.
public struct MenuBarContentView: View {
    @Bindable var state = AppState.shared
    @State private var showingMultiOutputSheet = false
    @State private var multiOutputName = "Headphones + Virtual Mic"
    @State private var selectedDeviceUIDsForMultiOutput: Set<String> = []

    @State private var showingMultiMicSheet = false
    @State private var multiMicName = "Combined Microphones"
    @State private var selectedDeviceUIDsForMultiMic: Set<String> = []
    @State private var setAsDefaultInputUponCreation = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            // Header
            headerView

            Divider()

            // Master Audio Routing & Devices
            masterDevicesSection

            Divider()

            // Desktop to Mic Routing Card
            desktopToMicCard

            Divider()

            // Microphones Section
            microphonesSection

            Divider()

            // Footer
            footerView
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            state.refresh()
        }
        .sheet(isPresented: $showingMultiOutputSheet) {
            multiOutputSheetView
        }
        .sheet(isPresented: $showingMultiMicSheet) {
            multiMicSheetView
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            Text("AppAudioRouter")
                .font(.headline)
            Spacer()
            Button(action: {
                state.refresh()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh audio processes and devices")
        }
    }

    // MARK: - Master Section

    private var masterDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Master Output:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)

                Picker("", selection: Binding(
                    get: { state.defaultOutputDevice?.id ?? 0 },
                    set: { state.setDefaultOutput(id: $0) }
                )) {
                    ForEach(state.visibleOutputDevices) { dev in
                        Text(dev.name).tag(dev.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            HStack {
                Text("Master Input:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)

                Picker("", selection: Binding(
                    get: { state.defaultInputDevice?.id ?? 0 },
                    set: { state.setDefaultInput(id: $0) }
                )) {
                    ForEach(state.visibleInputDevices) { dev in
                        Text(dev.name).tag(dev.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    // MARK: - Desktop to Mic Routing

    private var desktopToMicCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "broadcast")
                    .foregroundColor(state.isDesktopToMicEnabled ? .green : .secondary)
                    .font(.system(size: 13))

                Text("Desktop Audio to Virtual Mic")
                    .font(.system(size: 12, weight: .bold))

                if state.isDesktopToMicEnabled {
                    if state.isDesktopMuted {
                        Text("MUTED")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.18))
                            .foregroundColor(.red)
                            .cornerRadius(3)
                    } else if state.desktopPeakLevel > 0.02 {
                        Text("LIVE • SIGNAL")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18))
                            .foregroundColor(.green)
                            .cornerRadius(3)
                    } else {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18))
                            .foregroundColor(.green)
                            .cornerRadius(3)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { state.isDesktopToMicEnabled },
                    set: { _ in state.toggleDesktopToMic() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // Desktop Audio Gauge (Level Meter), Volume Slider, and Controls
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    // Gauge On/Off button
                    Button(action: {
                        state.toggleDesktopMeter()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: state.isDesktopMeterEnabled ? "gauge.with.dots.needle.bottom.50percent" : "gauge.with.dots.needle.bottom.0percent")
                                .font(.system(size: 10))
                            Text(state.isDesktopMeterEnabled ? "Gauge: ON" : "Gauge: OFF")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(state.isDesktopMeterEnabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                        .foregroundColor(state.isDesktopMeterEnabled ? .green : .secondary)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle the desktop audio meter gauge ON or OFF")

                    // Live Level Meter Bar
                    if state.isDesktopMeterEnabled && state.isDesktopToMicEnabled {
                        LevelMeterView(level: state.desktopPeakLevel)
                            .frame(maxWidth: .infinity)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 6)
                            .overlay(
                                Text(state.isDesktopToMicEnabled ? "METER OFF" : "OFF")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.secondary.opacity(0.6))
                            )
                    }

                    // Mute / Unmute Button
                    Button(action: {
                        state.toggleDesktopMute()
                    }) {
                        Image(systemName: state.isDesktopMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(state.isDesktopMuted ? .red : (state.isDesktopToMicEnabled ? .primary : .secondary))
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.isDesktopToMicEnabled)
                    .help(state.isDesktopMuted ? "Unmute desktop audio" : "Mute desktop audio")
                }

                // Volume slider & Signal detection text
                HStack(spacing: 6) {
                    // Signal indicator dot
                    Circle()
                        .fill(state.isDesktopToMicEnabled ? (state.isDesktopMuted ? Color.orange : (state.desktopPeakLevel > 0.02 ? Color.green : Color.secondary.opacity(0.4))) : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)

                    if !state.isDesktopToMicEnabled {
                        Text("Routing OFF")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    } else if state.isDesktopMuted {
                        Text("Muted")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    } else if state.desktopPeakLevel > 0.02 {
                        Text("Audio detected: \(Int(state.desktopPeakLevel * 100))%")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.green)
                    } else {
                        Text("Listening...")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text("Vol:")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { state.desktopVolume },
                            set: { state.setDesktopVolume($0) }
                        ),
                        in: 0.0...1.5
                    )
                    .controlSize(.mini)
                    .frame(width: 80)
                    .disabled(!state.isDesktopToMicEnabled)

                    Text("\(Int(state.desktopVolume * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(6)

            // AppAudioRouter Virtual Microphone status
            if state.isVirtualMicReady {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AggregateDeviceManager.virtualMicDeviceName)
                            .font(.system(size: 11, weight: .semibold))
                        Text("Desktop loopback device • Select BlackHole 2ch in Brave")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        state.setAppVirtualMicAsDefault()
                    }) {
                        Text("Set as Master Input")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Set AppAudioRouter Virtual Microphone as macOS master input")
                }
                .padding(6)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mic.badge.plus")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AggregateDeviceManager.virtualMicDeviceName)
                            .font(.system(size: 11, weight: .semibold))
                        Text("Click to create the ephemeral virtual microphone")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        _ = state.setupAppVirtualMicrophone(setAsDefault: false)
                    }) {
                        Text("Create Device")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(6)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(6)
            }

            // Virtual Input Test (Record & Playback)
            virtualInputTestSection

            if !state.hasVirtualLoopbackEngine {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Audio Driver Restart Needed")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        Text("Click to activate standalone audio engine (works without Zoom)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Initialize") {
                        state.restartCoreAudioEngine()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("For Gemini Live in Chrome, play YouTube in Safari and select BlackHole 2ch as Chrome's microphone. Exclude Chrome below to prevent Gemini's reply audio feeding back.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("For Brave + GeForce NOW, select BlackHole 2ch explicitly in Brave's site microphone settings; keep GeForce NOW on your physical mic. Avoid Automatically in Brave.")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.85))
                }
            }

            DisclosureGroup("Exclude apps from desktop capture") {
                if state.desktopAudioExclusionCandidates.isEmpty {
                    Text("No running apps found. Refresh after opening the app you want to exclude.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(state.desktopAudioExclusionCandidates) { process in
                        if let bundleID = process.bundleIdentifier {
                            Toggle(isOn: Binding(
                                get: { state.excludedDesktopAudioBundleIDs.contains(bundleID) },
                                set: { state.setDesktopAudioExcluded(bundleIdentifier: bundleID, excluded: $0) }
                            )) {
                                HStack(spacing: 5) {
                                    Text(process.name).font(.system(size: 10))
                                    if process.isAudioActive {
                                        Text("AUDIO")
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    if !state.excludedDesktopAudioBundleIDs.isEmpty {
                        Text("Excluded apps need active audio when routing starts. Refresh and restart routing if an app starts audio later.")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .font(.system(size: 9, weight: .medium))

            if !state.unresolvedDesktopTapExcludedBundleIDs.isEmpty {
                Text("Some selected apps have no active audio process yet. Start their audio, refresh, then turn routing off and on.")
                    .font(.system(size: 8))
                    .foregroundColor(.orange)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Virtual Input Test Section

    private var virtualInputTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform.badge.mic")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
                Text("Virtual Input Test (Record & Playback)")
                    .font(.system(size: 11, weight: .bold))

                Spacer()

                switch state.testState {
                case .idle:
                    Text("Ready")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                case .recording(let elapsed, let maxDur):
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("REC \(String(format: "%.1fs / %.0fs", elapsed, maxDur))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                case .recorded(let duration, _):
                    Text("Ready (\(String(format: "%.1fs", duration)))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.green)
                case .playing(let elapsed, let duration):
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                        Text("\(String(format: "%.1fs / %.1fs", elapsed, duration))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
            }

            // Controls & live meters according to state
            switch state.testState {
            case .idle:
                HStack(spacing: 6) {
                    Button(action: {
                        state.startVirtualInputTest(duration: 5.0, autoPlay: true)
                    }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                            Text("Record 5s & Play Test")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Text("Records virtual mic & plays back through speakers")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }

            case .recording:
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        LevelMeterView(level: state.testPeakLevel)
                            .frame(maxWidth: .infinity)

                        Button(action: {
                            state.stopVirtualInputRecording()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 8))
                                Text("Stop & Play")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Text("Recording live sound routed to Virtual Microphone...")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }

            case .recorded:
                HStack(spacing: 6) {
                    Button(action: {
                        state.startVirtualInputPlayback()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                            Text("Play Test Audio")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(action: {
                        state.startVirtualInputTest(duration: 5.0, autoPlay: true)
                    }) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("Re-record")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button(action: {
                        state.resetVirtualInputTest()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear test recording")
                }

            case .playing:
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        LevelMeterView(level: state.testPeakLevel)
                            .frame(maxWidth: .infinity)

                        Button(action: {
                            state.stopVirtualInputPlayback()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 8))
                                Text("Stop")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Text("Playing through speakers: this is the exact sound received by other apps.")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - Microphones Section

    private var microphonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Microphones (\(state.physicalInputDevices.count))")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
            }

            if state.physicalInputDevices.isEmpty {
                Text("No physical microphones detected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 6) {
                    ForEach(state.physicalInputDevices) { mic in
                        microphoneRow(mic)
                    }
                }
            }
        }
    }

    private func microphoneRow(_ mic: AudioDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(mic.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(mic.inputChannelCount) ch • \(Int(mic.sampleRate)) Hz")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Route into Virtual Mic button
                Button(action: {
                    state.toggleMicRoute(device: mic)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: state.isMicRouted(forMic: mic.uid) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.system(size: 10))
                        Text(state.isMicRouted(forMic: mic.uid) ? "To Virtual Mic" : "Mix")
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.isMicRouted(forMic: mic.uid) ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .foregroundColor(state.isMicRouted(forMic: mic.uid) ? .green : .secondary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Mix this microphone into Virtual Mic (so other apps/meetings can hear it)")

                // Mute Button
                Button(action: {
                    state.toggleMicMute(device: mic)
                }) {
                    Image(systemName: state.isMuted(forMic: mic.uid) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(state.isMuted(forMic: mic.uid) ? .red : .primary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }

            // Volume Slider and Meter
            HStack(spacing: 8) {
                LevelMeterView(level: state.peakLevel(forMic: mic.uid))
                    .frame(width: 40)

                Slider(
                    value: Binding(
                        get: { state.volume(forMic: mic.uid) },
                        set: { state.setMicVolume(device: mic, volume: $0) }
                    ),
                    in: 0.0...1.5
                )
                .controlSize(.mini)

                Text("\(Int(state.volume(forMic: mic.uid) * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Button("Combine Outputs...") {
                showingMultiOutputSheet = true
            }
            .buttonStyle(.link)
            .font(.caption)

            Text("•")
                .foregroundColor(.secondary)
                .font(.caption)

            Button("Combine Microphones...") {
                showingMultiMicSheet = true
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Multi-Output Sheet

    private var multiOutputSheetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Multi-Output Device")
                .font(.headline)

            Text("Select audio devices to play simultaneously:")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Device Name", text: $multiOutputName)
                .textFieldStyle(.roundedBorder)

            List(state.outputDevices) { dev in
                Toggle(dev.name, isOn: Binding(
                    get: { selectedDeviceUIDsForMultiOutput.contains(dev.uid) },
                    set: { selected in
                        if selected {
                            selectedDeviceUIDsForMultiOutput.insert(dev.uid)
                        } else {
                            selectedDeviceUIDsForMultiOutput.remove(dev.uid)
                        }
                    }
                ))
            }
            .frame(height: 150)

            HStack {
                Spacer()
                Button("Cancel") {
                    showingMultiOutputSheet = false
                }
                Button("Create") {
                    state.createMultiOutput(
                        name: multiOutputName,
                        uids: Array(selectedDeviceUIDsForMultiOutput)
                    )
                    showingMultiOutputSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDeviceUIDsForMultiOutput.count < 2)
            }
        }
        .padding(16)
        .frame(width: 350)
    }

    // MARK: - Multi-Mic Sheet

    private var multiMicSheetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Aggregate Microphone")
                .font(.headline)

            Text("Select microphones to combine into a single aggregate audio device:")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Device Name", text: $multiMicName)
                .textFieldStyle(.roundedBorder)

            List(state.inputDevices) { dev in
                Toggle(isOn: Binding(
                    get: { selectedDeviceUIDsForMultiMic.contains(dev.uid) },
                    set: { selected in
                        if selected {
                            selectedDeviceUIDsForMultiMic.insert(dev.uid)
                        } else {
                            selectedDeviceUIDsForMultiMic.remove(dev.uid)
                        }
                    }
                )) {
                    HStack {
                        Text(dev.name)
                        Spacer()
                        Text("\(dev.inputChannelCount) ch")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 150)

            Toggle("Set as Master Input upon creation", isOn: $setAsDefaultInputUponCreation)
                .font(.caption)

            HStack {
                Spacer()
                Button("Cancel") {
                    showingMultiMicSheet = false
                }
                Button("Create") {
                    state.createAggregateInput(
                        name: multiMicName,
                        uids: Array(selectedDeviceUIDsForMultiMic),
                        setAsDefault: setAsDefaultInputUponCreation
                    )
                    showingMultiMicSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDeviceUIDsForMultiMic.count < 2)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

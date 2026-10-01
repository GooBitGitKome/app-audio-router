import Foundation
import CoreAudio
import AppAudioRouterCore

@main
struct AppAudioRouterCLI {
    static func main() async {
        let args = CommandLine.arguments

        if args.count < 2 || args.contains("-h") || args.contains("--help") {
            printHelp()
            return
        }

        let command = args[1]
        switch command {
        case "devices":
            listDevices()
        case "processes":
            listProcesses()
        case "tap":
            await runTap(args: Array(args.dropFirst(2)))
        case "multi-output":
            createMultiOutput(args: Array(args.dropFirst(2)))
        case "multi-input", "aggregate-input", "combine-mics":
            createMultiInput(args: Array(args.dropFirst(2)))
        case "setup-virtual-mic", "setup-desktop-mic", "desktop-mic":
            setupVirtualMic(args: Array(args.dropFirst(2)))
        case "cleanup-virtual-mic", "destroy-virtual-mic":
            cleanupVirtualMic()
        case "test-virtual-mic", "test-input":
            await runVirtualInputTest(args: Array(args.dropFirst(2)))
        case "test-tone":
            await runToneTest()
        case "diagnose":
            await runDiagnose()
        default:
            print("Unknown command: \(command)")
            printHelp()
        }
    }

    static func printHelp() {
        print("""
        AppAudioRouter CLI - Audio Routing & Management Utility

        Usage:
          app-audio-router devices                  List all physical and virtual audio devices
          app-audio-router processes                List running audio processes
          app-audio-router tap --pid <pid>          Tap and monitor an audio process
          app-audio-router multi-output <uid1> ...  Create a Multi-Output device
          app-audio-router multi-input <uid1> ...   Create an Aggregate Microphone (Multi-Input) device
          app-audio-router setup-virtual-mic [--set-default] Setup 'AppAudioRouter Virtual Microphone'
          app-audio-router cleanup-virtual-mic      Destroy 'AppAudioRouter Virtual Microphone'
          app-audio-router test-virtual-mic [sec]   Record & playback test from Virtual Microphone
          app-audio-router diagnose                 Diagnose audio engine and virtual mic pipeline
        """)
    }

    static func listDevices() {
        let devices = AudioDeviceManager.shared.refreshDevices()
        print("=== Audio Devices (\(devices.count)) ===")
        for dev in devices {
            var flags: [String] = []
            if dev.isDefaultOutput { flags.append("DEFAULT_OUT") }
            if dev.isDefaultInput { flags.append("DEFAULT_IN") }
            if dev.isVirtual { flags.append("VIRTUAL") }
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"

            print("• [\(dev.id)] \(dev.name) (\(dev.manufacturer))\(flagStr)")
            print("    UID: \(dev.uid)")
            print("    Channels: In=\(dev.inputChannelCount), Out=\(dev.outputChannelCount), Rate: \(Int(dev.sampleRate))Hz")
        }
    }

    static func listProcesses() {
        let processes = AudioProcessManager.shared.refreshProcesses()
        print("=== Active Audio Processes (\(processes.count)) ===")
        for proc in processes {
            let daemonStr = proc.isSystemDaemon ? " [Daemon]" : ""
            print("• PID \(proc.pid): \(proc.name) (\(proc.bundleIdentifier ?? "no bundle"))\(daemonStr)")
        }
    }

    static func runTap(args: [String]) async {
        guard let pidIndex = args.firstIndex(of: "--pid"), pidIndex + 1 < args.count,
              let pid = pid_t(args[pidIndex + 1]) else {
            print("Error: Missing --pid <pid>")
            return
        }

        guard let proc = AudioProcessManager.shared.findProcess(byPID: pid) else {
            print("Error: Could not find audio process for PID \(pid)")
            return
        }

        print("Starting tap for PID \(pid) (\(proc.name))...")
        let success = AudioRoutingEngine.shared.startTapping(process: proc)
        if !success {
            print("Failed to start tap. (Check audio permissions or whether process is playing audio)")
            return
        }

        print("Tap active! Monitoring audio peak levels (Ctrl+C to stop)...")
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let peak = AudioRoutingEngine.shared.getPeakLevel(pid: pid)
            let barCount = Int(peak * 30)
            let bar = String(repeating: "█", count: barCount) + String(repeating: "-", count: 30 - barCount)
            print("\rPeak: [\(bar)] \(Int(peak * 100))%", terminator: "")
            fflush(stdout)
        }
        print("\nStopping tap...")
        AudioRoutingEngine.shared.stopTapping(pid: pid)
    }

    static func createMultiOutput(args: [String]) {
        guard args.count >= 2 else {
            print("Error: Provide at least two device UIDs")
            return
        }
        let uids = args
        print("Creating Multi-Output device with UIDs: \(uids)...")
        if let deviceID = AggregateDeviceManager.shared.createMultiOutputDevice(
            name: "CLI Multi-Output Device",
            subDeviceUIDs: uids,
            isPrivate: false
        ) {
            print("Successfully created device with ID: \(deviceID)")
        } else {
            print("Failed to create device.")
        }
    }

    static func createMultiInput(args: [String]) {
        guard !args.isEmpty else {
            print("Error: Provide at least one device UID")
            return
        }
        let uids = args
        print("Creating Aggregate Microphone device with UIDs: \(uids)...")
        if let deviceID = AggregateDeviceManager.shared.createAggregateInputDevice(
            name: "CLI Combined Microphones",
            subDeviceUIDs: uids,
            isPrivate: false
        ) {
            let dev = AudioDeviceManager.shared.findDevice(byID: deviceID)
            let channels = dev?.inputChannelCount ?? 0
            print("Successfully created Aggregate Microphone device with ID: \(deviceID) (\(channels) input channels)")
        } else {
            print("Failed to create Aggregate Microphone device.")
        }
    }

    static func setupVirtualMic(args: [String]) {
        let setAsDefault = args.contains("--set-default")
        let allDevs = AudioDeviceManager.shared.refreshDevices()
        let loopbackDev = allDevs.first { dev in
            (dev.uid.lowercased().contains("blackhole") && !dev.uid.contains("VirtualDesktop")) || dev.uid.contains("zoom.us.zoomaudiodevice")
        } ?? allDevs.first { dev in
            dev.isVirtual && dev.inputChannelCount > 0 && dev.outputChannelCount > 0 && !dev.uid.contains("VirtualDesktop")
        } ?? allDevs.first { dev in
            dev.isVirtual && dev.inputChannelCount > 0 && dev.outputChannelCount > 0
        }

        guard let loopback = loopbackDev else {
            print("Error: No virtual loopback driver found. Please install BlackHole (brew install blackhole-2ch).")
            return
        }

        let micName = AggregateDeviceManager.virtualMicDeviceName
        if let existing = allDevs.first(where: { $0.isInput && ($0.name == micName || $0.name == "Desktop Input Microphone") }) {
            let subs = AggregateDeviceManager.shared.getSubDeviceUIDs(for: existing.id)
            if subs.contains(loopback.uid) && existing.name == micName {
                print("\(micName) already active (ID: \(existing.id)).")
                if setAsDefault {
                    _ = AudioDeviceManager.shared.setDefaultInputDevice(id: existing.id)
                    print("Set \(micName) as system default input.")
                }
                return
            }
            AggregateDeviceManager.shared.destroyVirtualMicrophone()
        }

        if let id = AggregateDeviceManager.shared.createVirtualMicrophone(subDeviceUID: loopback.uid) {
            print("Successfully created '\(micName)' with ID: \(id)")
            print("Device is now visible in Brave Browser, Chrome, Zoom, Google Meet, and macOS System Settings.")
            if setAsDefault {
                _ = AudioDeviceManager.shared.setDefaultInputDevice(id: id)
                print("Set \(micName) as system default input.")
            }
        } else {
            print("Failed to create \(micName).")
        }
    }

    static func cleanupVirtualMic() {
        let micName = AggregateDeviceManager.virtualMicDeviceName
        print("Cleaning up and destroying \(micName)...")
        AggregateDeviceManager.shared.destroyVirtualMicrophone()
        print("Done. Virtual microphone removed.")
    }

    static func runDiagnose() async {
        let allDevs = AudioDeviceManager.shared.refreshDevices()
        print("=== DIAGNOSTIC START ===")
        guard let loopback = allDevs.first(where: { ($0.uid.lowercased().contains("blackhole") && !$0.uid.contains("VirtualDesktop")) || $0.uid.contains("zoom.us.zoomaudiodevice") })
            ?? allDevs.first(where: { $0.isVirtual && $0.inputChannelCount > 0 && $0.outputChannelCount > 0 && !$0.uid.contains("VirtualDesktop") })
            ?? allDevs.first(where: { $0.uid.contains("VirtualDesktop") }) else {
            print("ERROR: No suitable loopback device found.")
            return
        }
        print("Selected Loopback Engine: \(loopback.name) (ID: \(loopback.id), UID: \(loopback.uid))")
        print("  Channels: In=\(loopback.inputChannelCount), Out=\(loopback.outputChannelCount), Rate: \(loopback.sampleRate)Hz")

        // Check AppAudioRouter Virtual Microphone
        let micName = AggregateDeviceManager.virtualMicDeviceName
        let virtualMic = allDevs.first(where: { $0.name == micName || $0.name == "Desktop Input Microphone" })
        if let mic = virtualMic {
            print("\(mic.name) found: (ID: \(mic.id), UID: \(mic.uid))")
            print("  Channels: In=\(mic.inputChannelCount), Out=\(mic.outputChannelCount), Rate: \(mic.sampleRate)Hz")
        } else {
            print("\(micName): NOT FOUND")
        }

        // Print stream format for loopback
        printStreamFormat(id: loopback.id, scope: kAudioDevicePropertyScopeInput, label: "Loopback Input Format")
        printStreamFormat(id: loopback.id, scope: kAudioDevicePropertyScopeOutput, label: "Loopback Output Format")
        if let mic = virtualMic {
            printStreamFormat(id: mic.id, scope: kAudioDevicePropertyScopeInput, label: "VirtualMic Input Format")
        }

        // Test output renderer
        print("\nTesting idle input on \(loopback.name)...")
        var idleCapturedNonZero = 0
        var idleMaxVal: Float = 0.0
        var idleProcID: AudioDeviceIOProcID?
        let idleQueue = DispatchQueue(label: "test.idle")
        AudioDeviceCreateIOProcIDWithBlock(&idleProcID, loopback.id, idleQueue) { (_, inInputData, _, _, _) in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for buf in abl {
                guard let data = buf.mData else { continue }
                let count = Int(buf.mDataByteSize) / 4
                let ptr = data.bindMemory(to: Float.self, capacity: count)
                for j in 0..<count {
                    let val = abs(ptr[j])
                    if val > idleMaxVal { idleMaxVal = val }
                    if val > 0.001 { idleCapturedNonZero += 1 }
                }
            }
        }
        if let procID = idleProcID {
            AudioDeviceStart(loopback.id, procID)
            try? await Task.sleep(nanoseconds: 500_000_000)
            AudioDeviceStop(loopback.id, procID)
            AudioDeviceDestroyIOProcID(loopback.id, procID)
        }
        print("  Idle input non-zero samples: \(idleCapturedNonZero), maxPeak: \(idleMaxVal)")

        print("\nTesting AudioOutputRenderer directly to \(loopback.name)...")
        let renderer = AudioOutputRenderer(deviceID: loopback.id, deviceUID: loopback.uid)
        let ring = AudioRingBuffer()
        renderer.addSourceBuffer(id: UUID(), buffer: ring)
        let started = renderer.start()
        print("Renderer start result: \(started), isRunning: \(renderer.isRunning)")

        // Put test sine wave into ring buffer
        var sineWave = [Float](repeating: 0, count: 1024)
        for i in 0..<512 {
            let sample = sin(Float(i) * 2.0 * .pi * 440.0 / 44100.0) * 0.8
            sineWave[i * 2] = sample
            sineWave[i * 2 + 1] = sample
        }

        // Setup input capture on the loopback device to see if it loops back
        var inputCapturedSamples: Int = 0
        var inputCallCount: Int = 0
        var maxPeakDetected: Float = 0.0
        var inputProcID: AudioDeviceIOProcID?
        let testQueue = DispatchQueue(label: "test.input")
        let inputStatus = AudioDeviceCreateIOProcIDWithBlock(&inputProcID, loopback.id, testQueue) { (_, inInputData, _, outOutputData, _) in
            inputCallCount += 1
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for buf in abl {
                guard let data = buf.mData else { continue }
                let count = Int(buf.mDataByteSize) / 4
                let ptr = data.bindMemory(to: Float.self, capacity: count)
                if inputCallCount == 2 {
                    let preview = (0..<min(10, count)).map { String(format: "%.4f", ptr[$0]) }.joined(separator: ", ")
                    print("  [DEBUG input raw samples 0..10]: \(preview)")
                    let int16Ptr = data.bindMemory(to: Int16.self, capacity: Int(buf.mDataByteSize) / 2)
                    let intPreview = (0..<min(10, Int(buf.mDataByteSize) / 2)).map { "\($0): \(int16Ptr[$0])" }.joined(separator: ", ")
                    print("  [DEBUG input if Int16]: \(intPreview)")
                }
                for j in 0..<count {
                    let val = abs(ptr[j])
                    if val > maxPeakDetected { maxPeakDetected = val }
                    if val > 0.001 { inputCapturedSamples += 1 }
                }
            }
        }
        print("Input IOProc creation status: \(inputStatus)")
        if inputStatus == noErr, let procID = inputProcID {
            let startStatus = AudioDeviceStart(loopback.id, procID)
            print("Input AudioDeviceStart status: \(startStatus)")
        }

        // Write sine wave repeatedly for 1 second
        print("Writing sine wave to loopback output...")
        for _ in 0..<10 {
            sineWave.withUnsafeBufferPointer { ptr in
                ring.write(frames: 512, from: ptr.baseAddress!)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if let procID = inputProcID {
            AudioDeviceStop(loopback.id, procID)
            AudioDeviceDestroyIOProcID(loopback.id, procID)
        }
        renderer.stop()

        print("Results:")
        print("  Renderer renderCallCount: \(renderer.renderCallCount)")
        print("  Input IOProc callCount: \(inputCallCount)")
        print("  Input non-zero samples captured: \(inputCapturedSamples)")
        print("  Max peak detected on loopback input: \(maxPeakDetected)")

        // Test Global Tap Buffer Format
        if #available(macOS 14.2, *) {
            print("\nTesting Global Desktop Tap...")
            if let (tapID, tapUID) = ProcessTap.createGlobalTap() {
                let tapAgg = TapAggregateDevice(tapUID: tapUID, deviceName: "DiagDesktopTap")
                if tapAgg.create() {
                    var targetRate: Float64 = 48000.0
                    var rateAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyNominalSampleRate,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    let setErr = AudioObjectSetPropertyData(tapAgg.aggregateDeviceID, &rateAddr, 0, nil, UInt32(MemoryLayout<Float64>.size), &targetRate)
                    printStreamFormat(id: tapAgg.aggregateDeviceID, scope: kAudioDevicePropertyScopeInput, label: "Tap Aggregate Input Format (after setRate \(setErr))")
                    printStreamFormat(id: tapAgg.aggregateDeviceID, scope: kAudioDevicePropertyScopeOutput, label: "Tap Aggregate Output Format")
                    tapAgg.onAudioBuffer = { bufList in
                        let numBufs = bufList.pointee.mNumberBuffers
                        let first = bufList.pointee.mBuffers
                        print("  Tap Buffer received: numBuffers=\(numBufs), chans=\(first.mNumberChannels), byteSize=\(first.mDataByteSize)")
                        tapAgg.onAudioBuffer = nil
                    }
                    if tapAgg.start() {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        tapAgg.stop()
                    }
                    tapAgg.destroy()
                }
                AudioHardwareDestroyProcessTap(tapID)
            } else {
                print("  Failed to create global tap (check audio permissions).")
            }
        }

        // Test Desktop Audio to Mic
        print("\nTesting AudioRoutingEngine.setDesktopAudioToMic with \(loopback.name)...")
        AudioRoutingEngine.shared.setDesktopAudioToMic(enabled: true, virtualMicDeviceUID: loopback.uid)
        print("  isDesktopAudioToMicEnabled: \(AudioRoutingEngine.shared.isDesktopAudioToMicEnabled)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        AudioRoutingEngine.shared.setDesktopAudioToMic(enabled: false)
        print("=== DIAGNOSTIC END ===")
    }

    static func printStreamFormat(id: AudioObjectID, scope: AudioObjectPropertyScope, label: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreamFormat),
            mScope: scope,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &asbd)
        if status == noErr {
            let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            print("  \(label): Rate=\(asbd.mSampleRate), Chans=\(asbd.mChannelsPerFrame), Bits=\(asbd.mBitsPerChannel), BytesPerFrame=\(asbd.mBytesPerFrame), Float=\(isFloat), SignedInt=\(isSignedInt), Interleaved=\(isInterleaved), Flags=0x\(String(asbd.mFormatFlags, radix: 16))")
        } else {
            print("  \(label): Failed to get format (status \(status))")
        }
    }

    static func runVirtualInputTest(args: [String]) async {
        let seconds = Double(args.first ?? "3") ?? 3.0
        print("=== Virtual Input Test ===")
        print("Testing Virtual Microphone recording for \(seconds)s, then playing back...")

        guard let targetID = VirtualInputTester.shared.resolveTargetDeviceID() else {
            print("ERROR: Virtual Microphone or loopback device not found.")
            return
        }

        let dev = AudioDeviceManager.shared.findDevice(byID: targetID)
        print("Target Device: \(dev?.name ?? "ID \(targetID)") (ID: \(targetID))")

        final class Resumer: @unchecked Sendable {
            private var continuation: CheckedContinuation<Void, Never>?
            private let lock = NSLock()
            private var hasStarted = false
            private var hasPlayed = false

            init(continuation: CheckedContinuation<Void, Never>) {
                self.continuation = continuation
            }

            func markStarted() {
                lock.lock()
                hasStarted = true
                lock.unlock()
            }

            func markPlayed() {
                lock.lock()
                hasPlayed = true
                lock.unlock()
            }

            var isPlayed: Bool {
                lock.lock()
                defer { lock.unlock() }
                return hasPlayed
            }

            func resumeIfStarted() {
                lock.lock()
                guard hasStarted else {
                    lock.unlock()
                    return
                }
                let cont = self.continuation
                self.continuation = nil
                lock.unlock()
                cont?.resume()
            }

            func resumeImmediately() {
                lock.lock()
                let cont = self.continuation
                self.continuation = nil
                lock.unlock()
                cont?.resume()
            }
        }

        await withCheckedContinuation { continuation in
            let resumer = Resumer(continuation: continuation)

            VirtualInputTester.shared.onStateChanged = { state in
                switch state {
                case .recording(let elapsed, let maxDur):
                    resumer.markStarted()
                    print(String(format: "\r• Recording: %.1fs / %.1fs", elapsed, maxDur), terminator: "")
                    fflush(stdout)
                case .recorded(let duration, _):
                    if resumer.isPlayed {
                        print("\n✔ Playback finished. Test complete.")
                        resumer.resumeIfStarted()
                    } else {
                        resumer.markStarted()
                        print(String(format: "\n✔ Recorded %.1fs. Now playing back through speakers...", duration))
                    }
                case .playing(let elapsed, let duration):
                    resumer.markPlayed()
                    resumer.markStarted()
                    print(String(format: "\r• Playing: %.1fs / %.1fs", elapsed, duration), terminator: "")
                    fflush(stdout)
                case .idle:
                    print("\n✔ Test complete.")
                    resumer.resumeIfStarted()
                }
            }

            let started = VirtualInputTester.shared.startRecording(duration: seconds, autoPlayWhenDone: true)
            guard started else {
                print("ERROR: Failed to start recording from device ID \(targetID).")
                resumer.resumeImmediately()
                return
            }
        }
    }

    static func runToneTest() async {
        print("=== Tone Pipeline Test ===")
        guard let loopback = AudioDeviceManager.shared.refreshDevices().first(where: {
            ($0.uid.lowercased().contains("blackhole") && !$0.uid.contains("VirtualDesktop")) ||
            $0.uid.contains("zoom.us.zoomaudiodevice")
        }) else {
            print("ERROR: Loopback device not found.")
            return
        }

        print("Testing 440Hz sine wave route to \(loopback.name)...")
        let renderer = AudioOutputRenderer(deviceID: loopback.id, deviceUID: loopback.uid)
        let ring = AudioRingBuffer()
        renderer.addSourceBuffer(id: UUID(), buffer: ring)
        guard renderer.start() else {
            print("Failed to start renderer.")
            return
        }

        final class Flag: @unchecked Sendable {
            private var _val: Bool
            private let lock = NSLock()
            init(_ val: Bool) { _val = val }
            var value: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _val }
                set { lock.lock(); _val = newValue; lock.unlock() }
            }
        }
        let runningFlag = Flag(true)

        // Generate 440Hz sine wave at 0.6 amplitude
        Task.detached {
            var phase: Float = 0
            let step: Float = 2.0 * .pi * 440.0 / 48000.0
            var buf = [Float](repeating: 0, count: 1024)
            while runningFlag.value {
                for i in 0..<512 {
                    let s = sin(phase) * 0.6
                    phase += step
                    if phase > 2.0 * .pi { phase -= 2.0 * .pi }
                    buf[i * 2] = s
                    buf[i * 2 + 1] = s
                }
                buf.withUnsafeBufferPointer { ptr in
                    ring.write(frames: 512, from: ptr.baseAddress!)
                }
                try? await Task.sleep(nanoseconds: 10_000_000) // ~10ms
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        print("Recording 1.5s from Virtual Microphone...")
        let started = VirtualInputTester.shared.startRecording(duration: 1.5, autoPlayWhenDone: false)
        guard started else {
            print("Failed to start recording.")
            runningFlag.value = false
            renderer.stop()
            return
        }

        try? await Task.sleep(nanoseconds: 1_800_000_000)
        VirtualInputTester.shared.stopRecording(autoPlay: false)
        runningFlag.value = false
        renderer.stop()

        // Analyze WAV file
        let path = "\(FileManager.default.temporaryDirectory.path)/virtual_input_test.wav"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 44 else {
            print("ERROR: WAV file was not created.")
            return
        }

        let int16Data = data.subdata(in: 44..<data.count)
        let count = int16Data.count / 2
        int16Data.withUnsafeBytes { ptr in
            let s = ptr.bindMemory(to: Int16.self)
            var maxVal: Int16 = 0
            var zeroCrossings = 0
            var rmsSum: Double = 0
            for i in 0..<count {
                let val = abs(s[i])
                if val > maxVal { maxVal = val }
                if i > 0 && ((s[i-1] >= 0 && s[i] < 0) || (s[i-1] < 0 && s[i] >= 0)) {
                    zeroCrossings += 1
                }
                rmsSum += Double(s[i]) * Double(s[i])
            }
            let dur = Double(count) / (48000.0 * 2.0)
            let rms = sqrt(rmsSum / Double(count))
            let zcr = Double(zeroCrossings) / dur
            print("\n=== TONE TEST RESULTS ===")
            print(String(format: "  Duration: %.2fs", dur))
            print(String(format: "  Max Sample: %d / 32767 (%.1f%% of full scale)", maxVal, Float(maxVal) / 32767.0 * 100.0))
            print(String(format: "  RMS Level: %.1f (%.1f dBFS)", rms, 20.0 * log10(max(1.0, rms) / 32767.0)))
            print(String(format: "  Zero Crossings/sec: %.1f (Ideal for 440Hz: ~880)", zcr))
            if zcr > 750 && zcr < 1000 && maxVal > 15000 && maxVal < 25000 {
                print("  STATUS: PASSED! Clean, undistorted tone captured successfully.")
            } else {
                print("  STATUS: Verification warning - check sample values.")
            }
            print("=========================")
        }
    }
}

import Foundation
import CoreAudio
import AppKit
import Darwin

/// Observes and manages running audio client processes connected to CoreAudio.
public final class AudioProcessManager: @unchecked Sendable {
    public static let shared = AudioProcessManager()

    private let lock = NSLock()
    private var cachedProcesses: [AudioProcess] = []
    public var onProcessesChanged: (@Sendable ([AudioProcess]) -> Void)?

    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init() {
        refreshProcesses()
        setupListener()
    }

    deinit {
        removeListener()
    }

    // MARK: - Public Queries

    public func getAllProcesses() -> [AudioProcess] {
        lock.lock()
        defer { lock.unlock() }
        return cachedProcesses
    }

    public func getUserFacingProcesses() -> [AudioProcess] {
        return getAllProcesses().filter { !$0.isSystemDaemon }
    }

    public func findProcess(byPID pid: pid_t) -> AudioProcess? {
        return getAllProcesses().first { $0.pid == pid }
    }

    public func findProcess(byObjectID objectID: AudioObjectID) -> AudioProcess? {
        return getAllProcesses().first { $0.objectID == objectID || $0.objectIDs.contains(objectID) }
    }

    // MARK: - Process Refresh

    @discardableResult
    public func refreshProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        var coreAudioProcesses: [AudioProcess] = []
        if status == noErr, dataSize > 0 {
            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var processIDs = [AudioObjectID](repeating: 0, count: count)
            status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &processIDs
            )
            if status == noErr {
                for objID in processIDs {
                    if let proc = createAudioProcess(objectID: objID) {
                        coreAudioProcesses.append(proc)
                    }
                }
            }
        }

        // Query running GUI applications (both regular and accessory apps like menu bar players)
        let regularApps = NSWorkspace.shared.runningApplications.filter {
            ($0.activationPolicy == .regular || $0.activationPolicy == .accessory) &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !($0.bundleIdentifier?.starts(with: "com.apple.coreservices") == true) &&
            !($0.bundleIdentifier?.starts(with: "com.apple.dock") == true) &&
            !($0.bundleIdentifier?.starts(with: "com.apple.Spotlight") == true) &&
            !($0.bundleIdentifier?.starts(with: "com.apple.systemuiserver") == true)
        }

        var matchedCorePIDs = Set<pid_t>()
        var runningAppProcesses: [AudioProcess] = []

        for app in regularApps {
            let pid = app.processIdentifier
            let appBundleID = app.bundleIdentifier ?? ""
            let appBundleURLPath = app.bundleURL?.path ?? ""

            // Find all coreAudioProcesses that belong to this app (exact PID match, helper bundleID match, or bundle path match)
            let matchingCoreProcs = coreAudioProcesses.filter { coreProc in
                if coreProc.pid == pid { return true }
                if !appBundleID.isEmpty, let coreBID = coreProc.bundleIdentifier, coreBID.starts(with: appBundleID) {
                    return true
                }
                if !appBundleURLPath.isEmpty, let procPath = getExecutablePath(for: coreProc.pid), procPath.hasPrefix(appBundleURLPath) {
                    return true
                }
                return false
            }

            let name = app.localizedName ?? "Application"
            if !matchingCoreProcs.isEmpty {
                // Main app has active audio through itself or its helpers!
                for p in matchingCoreProcs {
                    matchedCorePIDs.insert(p.pid)
                }
                let allIDs = matchingCoreProcs.flatMap { $0.objectIDs }
                let primaryID = matchingCoreProcs[0].objectID
                runningAppProcesses.append(
                    AudioProcess(
                        objectID: primaryID,
                        objectIDs: allIDs,
                        pid: pid,
                        bundleIdentifier: appBundleID.isEmpty ? nil : appBundleID,
                        name: name,
                        isSystemDaemon: false,
                        isAudioActive: true
                    )
                )
            } else {
                runningAppProcesses.append(
                    AudioProcess(
                        objectID: 0,
                        objectIDs: [],
                        pid: pid,
                        bundleIdentifier: appBundleID.isEmpty ? nil : appBundleID,
                        name: name,
                        isSystemDaemon: false,
                        isAudioActive: false
                    )
                )
            }
        }

        // Include any remaining coreAudioProcesses not matched to a running GUI application
        var remainingCoreProcesses: [AudioProcess] = []
        for coreProc in coreAudioProcesses {
            if !matchedCorePIDs.contains(coreProc.pid) {
                remainingCoreProcesses.append(coreProc)
            }
        }

        var newProcesses = runningAppProcesses + remainingCoreProcesses

        // Sort so user applications come first (active audio first, then idle), alphabetically
        newProcesses.sort { (a, b) -> Bool in
            if a.isSystemDaemon != b.isSystemDaemon {
                return !a.isSystemDaemon && b.isSystemDaemon
            }
            if a.isAudioActive != b.isAudioActive {
                return a.isAudioActive && !b.isAudioActive
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        lock.lock()
        self.cachedProcesses = newProcesses
        let callback = self.onProcessesChanged
        lock.unlock()

        callback?(newProcesses)
        return newProcesses
    }

    // MARK: - Private Helpers

    private func createAudioProcess(objectID: AudioObjectID) -> AudioProcess? {
        let pid = getProcessPID(objectID: objectID)
        guard pid > 0 else { return nil }

        var bundleID = getProcessBundleID(objectID: objectID)
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let exePath = getExecutablePath(for: pid)
        let enclosingApp = exePath.flatMap { findEnclosingAppBundle(executablePath: $0) }

        var name: String
        var isSystemDaemon: Bool

        if let app = runningApp, let appName = app.localizedName, !appName.isEmpty {
            name = appName
            bundleID = bundleID ?? app.bundleIdentifier
            let isDaemonBundle = isKnownDaemonBundle(bundleID)
            isSystemDaemon = isDaemonBundle || ((app.activationPolicy == .prohibited) && (bundleID?.starts(with: "com.apple.") == true))
        } else if let enclosing = enclosingApp {
            name = enclosing.appName
            bundleID = bundleID ?? enclosing.bundleID
            isSystemDaemon = false
        } else if let bID = bundleID, !bID.isEmpty {
            let components = bID.split(separator: ".")
            name = components.last.map(String.init) ?? "PID \(pid)"
            isSystemDaemon = isKnownDaemonBundle(bID)
        } else if let bsdName = getProcessBSDName(for: pid), !bsdName.isEmpty {
            name = bsdName
            isSystemDaemon = isDaemonPath(exePath)
        } else {
            name = "Process \(pid)"
            isSystemDaemon = true
        }

        // Special handling for browser, electron, and media rendering helpers
        if let bID = bundleID?.lowercased() {
            if bID.contains("com.brave.browser") {
                isSystemDaemon = false
                if name.contains("helper") || name == "GPU" || name.contains("renderer") {
                    name = "Brave Browser (Audio Helper)"
                }
            } else if bID.contains("com.google.chrome") {
                isSystemDaemon = false
                if name.contains("helper") || name == "GPU" || name.contains("renderer") {
                    name = "Google Chrome (Audio Helper)"
                }
            } else if bID.contains("thebrowser.browser") {
                isSystemDaemon = false
                name = "Arc (Audio Helper)"
            } else if bID.contains("edgemac") {
                isSystemDaemon = false
                name = "Microsoft Edge (Audio Helper)"
            } else if bID == "com.apple.webkit.gpu" || bID.contains("webkit") {
                isSystemDaemon = false
                name = "Safari / WebKit Audio"
            } else if bID.contains("spotify") {
                isSystemDaemon = false
                name = "Spotify"
            } else if bID.contains("discord") {
                isSystemDaemon = false
                name = "Discord"
            }
        }

        if let path = exePath, (path.hasPrefix("/Applications") || path.hasPrefix("/Users") || path.contains(".app/")) {
            isSystemDaemon = false
        }

        return AudioProcess(
            objectID: objectID,
            objectIDs: [objectID],
            pid: pid,
            bundleIdentifier: bundleID,
            name: name,
            isSystemDaemon: isSystemDaemon,
            isAudioActive: true
        )
    }

    private func getExecutablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if length > 0 {
            return pathBuffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) }
            }
        }
        return nil
    }

    private func getProcessBSDName(for pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if length > 0 {
            return nameBuffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) }
            }
        }
        return nil
    }

    private func findEnclosingAppBundle(executablePath: String) -> (bundlePath: String, appName: String, bundleID: String?)? {
        let components = (executablePath as NSString).pathComponents
        var currentPath = ""
        for component in components {
            if currentPath.isEmpty || currentPath == "/" {
                currentPath = (currentPath == "/") ? "/\(component)" : component
            } else {
                currentPath += "/\(component)"
            }
            if component.hasSuffix(".app") {
                let bundle = Bundle(path: currentPath)
                let appName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? (component as NSString).deletingPathExtension
                let bID = bundle?.bundleIdentifier
                return (currentPath, appName, bID)
            }
        }
        return nil
    }

    private func isDaemonPath(_ path: String?) -> Bool {
        guard let p = path else { return true }
        if p.hasPrefix("/usr/sbin") || p.hasPrefix("/usr/libexec") || p.hasPrefix("/System/Library/Frameworks") || p.hasPrefix("/System/Library/PrivateFrameworks") {
            return true
        }
        return false
    }

    private func isKnownDaemonBundle(_ bundleID: String?) -> Bool {
        guard let bID = bundleID else { return true }
        if bID.starts(with: "com.apple.audio.") ||
           bID.starts(with: "com.apple.cmio.") ||
           bID.contains("assistantd") ||
           bID.contains("audiomxd") ||
           bID.contains("avconferenced") ||
           bID.contains("cloudpaird") ||
           bID.contains("mediaanalysisd") ||
           bID.contains("mediaremoted") ||
           bID.contains("replayd") ||
           bID.contains("AirPlayXPCHelper") {
            return true
        }
        return false
    }

    private func getProcessPID(objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioProcessPropertyPID),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : -1
    }

    private func getProcessBundleID(objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioProcessPropertyBundleID),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var unmanagedStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &unmanagedStr)
        if status == noErr, let str = unmanagedStr?.takeRetainedValue() as String? {
            return str
        }
        return nil
    }

    // MARK: - Listener

    private func setupListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] (_, _) in
            guard let self = self else { return }
            _ = self.refreshProcesses()
        }
        self.processListListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .utility),
            block
        )

        let launchObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshProcesses()
        }
        let termObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshProcesses()
        }
        self.workspaceObservers = [launchObs, termObs]
    }

    private func removeListener() {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        guard let block = processListListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .utility),
            block
        )
    }
}

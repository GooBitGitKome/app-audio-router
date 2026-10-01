import SwiftUI
import AppKit

@main
struct AppAudioRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("AppAudioRouter", systemImage: "waveform.circle.fill") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar accessory without appearing in Dock
        NSApp.setActivationPolicy(.accessory)
        _ = AppState.shared.setupAppVirtualMicrophone()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up ephemeral virtual microphone when app closes
        AppState.shared.cleanupAppVirtualMicrophone()
    }
}

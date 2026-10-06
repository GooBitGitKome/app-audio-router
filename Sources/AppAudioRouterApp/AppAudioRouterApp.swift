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
        // Keep the menu bar controls and expose a normal Dock icon so users
        // can keep the app in the Dock and quit it using standard macOS UI.
        NSApp.setActivationPolicy(.regular)
        _ = AppState.shared.setupAppVirtualMicrophone()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up ephemeral virtual microphone when app closes
        AppState.shared.cleanupAppVirtualMicrophone()
    }
}

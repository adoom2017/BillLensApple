#if os(macOS)
import SwiftUI
import AppKit
import BillLensShared
import BillLensAppleServices

final class BillLensAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        RustBridge.registerSttBackend()
        NSApp.registerForRemoteNotifications()
        Task { @MainActor in
            await SpeechCaptureService.shared.bootstrapPermissions()
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        CloudKitSyncService.shared.handleRemoteNotification()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct BillLensMacApp: App {
    @NSApplicationDelegateAdaptor(BillLensAppDelegate.self) private var appDelegate
    @StateObject private var store = BillLensStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
#endif

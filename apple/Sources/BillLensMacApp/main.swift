#if os(macOS)
import SwiftUI
import AppKit
import BillLensShared
import BillLensAppleServices

final class BillLensAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    private func installDockIcon() {
        let bundleIconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let sourceIconURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AppIcon.icns")

        for iconURL in [bundleIconURL, sourceIconURL] {
            guard let iconURL, let iconImage = NSImage(contentsOf: iconURL) else {
                continue
            }
            NSApp.applicationIconImage = iconImage
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installDockIcon()
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
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
    }
}
#endif

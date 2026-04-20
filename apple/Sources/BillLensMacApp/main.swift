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
        Task { @MainActor in
            await SpeechCaptureService.shared.bootstrapPermissions()
        }
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

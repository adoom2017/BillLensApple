import SwiftUI
import AppKit
import BillLensShared

final class BillLensAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.minSize = NSSize(width: 1180, height: 760)
            if window.frame.width < 1180 || window.frame.height < 760 {
                window.setContentSize(NSSize(width: max(window.frame.width, 1180), height: max(window.frame.height, 760)))
            }
            window.makeKeyAndOrderFront(nil)
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

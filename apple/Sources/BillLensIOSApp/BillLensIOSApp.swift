#if os(iOS)
import SwiftUI
import UIKit
import BillLensShared
import BillLensAppleServices

final class BillLensIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let ok = await CloudKitSyncService.shared.handleRemoteNotificationAsync()
            completionHandler(ok ? .newData : .failed)
        }
    }
}

@main
struct BillLensIOSApp: App {
    @UIApplicationDelegateAdaptor(BillLensIOSAppDelegate.self) private var appDelegate
    @StateObject private var store = BillLensStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task {
                    RustBridge.registerSttBackend()
                    await SpeechCaptureService.shared.bootstrapPermissions()
                }
        }
    }
}
#endif

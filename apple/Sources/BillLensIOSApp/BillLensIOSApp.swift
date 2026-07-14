#if os(iOS)
import SwiftUI
import UIKit
import BillLensShared
import BillLensAppleServices

@MainActor
final class BillLensIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        RustBridge.registerSttBackend()
        RustBridge.registerLocalLlmBackend()
        application.registerForRemoteNotifications()
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        LocalLlmRuntime.shared.unload(reason: "memory_pressure")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        precondition(
            identifier == LocalModelManager.backgroundSessionIdentifier,
            "收到未知后台 URLSession：\(identifier)"
        )
        Task { @MainActor in
            LocalModelManager.shared.setBackgroundCompletionHandler(completionHandler)
        }
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task {
                    await SpeechCaptureService.shared.bootstrapPermissions()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LocalLlmRuntime.shared.resumeAfterBackground()
                    case .background:
                        LocalLlmRuntime.shared.suspendForBackground()
                    case .inactive:
                        break
                    @unknown default:
                        preconditionFailure("未知 scenePhase：\(phase)")
                    }
                }
        }
    }
}
#endif

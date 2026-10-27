#if os(iOS)
import SwiftUI
import UIKit
import BackgroundTasks
import BillLensShared
import BillLensAppleServices

@MainActor
final class SubscriptionBackgroundRefreshCoordinator {
    static let shared = SubscriptionBackgroundRefreshCoordinator()
    static let taskIdentifier = "com.shendongchun.BillLensApple.subscription-refresh"

    private weak var store: BillLensStore?

    private init() {}

    func attach(store: BillLensStore) {
        self.store = store
    }

    func register() {
        // launchHandler 在 `using` 指定的队列上执行。本类是 MainActor 隔离的，闭包也会被推断为
        // MainActor 隔离；传 nil 会在后台队列调用，触发 Swift 6 运行时隔离检查崩溃。必须用主队列。
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                preconditionFailure("订阅后台任务类型错误：\(type(of: task))")
            }
            self.handle(refreshTask)
        }
        precondition(registered, "订阅后台任务注册失败：\(Self.taskIdentifier)")
    }

    func schedule() throws {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try BGTaskScheduler.shared.submit(request)
        AppLogger.log("subscription.background.schedule", "earliest_in_minutes=15")
    }

    private func handle(_ backgroundTask: BGAppRefreshTask) {
        guard let store else {
            preconditionFailure("执行订阅后台任务时 BillLensStore 尚未附加")
        }

        let worker = Task { @MainActor in
            do {
                let charged = try await store.processDueSubscriptions(trigger: "background_refresh")
                try Task.checkCancellation()
                try schedule()
                AppLogger.log("subscription.background.complete", "charged=\(charged)")
                // 邮箱账单搭同一后台任务顺带检查（订阅维护先完成并已调度下一次）；失败只记录在
                // 同步状态里。过期取消时不报告订阅检查失败。
                await store.syncMailbox(trigger: "background_refresh")
                backgroundTask.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                AppLogger.log("subscription.background.error", error.localizedDescription)
                store.errorText = error.localizedDescription
                store.statusText = "后台订阅检查失败"
                backgroundTask.setTaskCompleted(success: false)
            }
        }
        // 系统在任意队列调用 expirationHandler；@Sendable 闭包不继承 MainActor 隔离，只取消 Task。
        backgroundTask.expirationHandler = { @Sendable in
            worker.cancel()
        }
    }
}

@MainActor
final class BillLensIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        RustBridge.registerSttBackend()
        RustBridge.registerLocalLlmBackend()
        SubscriptionBackgroundRefreshCoordinator.shared.register()
        if CloudKitSyncService.shared.isEnabledForCurrentProcess {
            application.registerForRemoteNotifications()
        }
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
@MainActor
struct BillLensIOSApp: App {
    @UIApplicationDelegateAdaptor(BillLensIOSAppDelegate.self) private var appDelegate
    @StateObject private var store: BillLensStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = BillLensStore()
        _store = StateObject(wrappedValue: store)
        SubscriptionBackgroundRefreshCoordinator.shared.attach(store: store)
    }

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
                        store.processDueSubscriptionsReportingErrors(trigger: "app_active")
                    case .background:
                        LocalLlmRuntime.shared.suspendForBackground()
                        do {
                            try SubscriptionBackgroundRefreshCoordinator.shared.schedule()
                        } catch {
                            AppLogger.log("subscription.background.schedule.error", error.localizedDescription)
                            store.errorText = error.localizedDescription
                            store.statusText = "后台订阅检查调度失败"
                        }
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

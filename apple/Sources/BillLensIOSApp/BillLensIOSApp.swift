import SwiftUI
import BillLensShared
import BillLensAppleServices

@main
struct BillLensIOSApp: App {
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

import CloudKit
import OSLog
import SwiftUI
import UIKit

@main
struct CodexBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SnapshotSyncCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .task {
                    self.appDelegate.coordinator = self.coordinator
                    self.coordinator.onSnapshotUpdate = { snapshot in
                        Task { await LiveActivityController.shared.refreshAll(from: snapshot) }
                    }
                    self.coordinator.start()
                    UIApplication.shared.registerForRemoteNotifications()
                }
        }
        .onChange(of: self.scenePhase) { _, phase in
            if phase == .active { self.coordinator.onForeground() }
        }
    }
}

/// Handles CloudKit silent pushes: when the Mac writes a new snapshot, APNs (via CloudKit,
/// no server of our own) wakes the app to pull it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "com.steipete.codexbar.ios", category: "AppDelegate")
    weak var coordinator: SnapshotSyncCoordinator?

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult
    {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            return .noData
        }
        self.log.info("received CloudKit push; refreshing snapshot")
        await self.coordinator?.manualRefresh()
        return .newData
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error)
    {
        self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

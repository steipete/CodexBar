import BackgroundTasks
import SwiftUI

@main
struct CodexBariOSApp: App {
    private static let refreshTaskIdentifier = "com.snode.codexbar.ios.refresh"

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: self.model)
                .task {
                    await self.model.activateAutomaticRefresh()
                    self.scheduleBackgroundRefresh()
                }
                .onChange(of: self.scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task {
                            await self.model.activateAutomaticRefresh()
                        }
                    case .background:
                        self.model.prepareForNextActivationRefresh()
                        self.scheduleBackgroundRefresh()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskIdentifier)) {
            await self.model.performBackgroundRefresh()
            await MainActor.run {
                self.scheduleBackgroundRefresh()
            }
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(DashboardModel.automaticRefreshInterval)

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return
        }
    }
}

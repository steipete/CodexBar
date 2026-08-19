import CodexBarCore
import Foundation
import Observation

@MainActor
extension UsageStore {
    func sharedSpendDashboardController() -> SpendDashboardController {
        if let controller = self.sharedSpendDashboardControllerStorage {
            return controller
        }
        let controller = SpendDashboardController(
            requestBuilder: { [weak self] mode in
                guard let self else {
                    return SpendDashboardLoadRequest(
                        configuration: SpendDashboardConfiguration(
                            costUsageEnabled: false,
                            providerIDs: [],
                            codexAccountIdentities: []),
                        capturedInputs: [],
                        unavailableSourceIDs: [],
                        codexRequests: [],
                        now: Date(),
                        force: false)
                }
                return await SpendDashboardSource.makeRequest(
                    settings: self.settings,
                    store: self,
                    mode: mode)
            },
            cachedLoader: { request in
                await SpendDashboardSource.loadCached(request)
            },
            publicationHandler: { [weak self] publication in
                self?.spendDashboardPublication = publication
            })
        self.sharedSpendDashboardControllerStorage = controller
        return controller
    }

    func startSharedSpendDashboardPublication() {
        guard !self.sharedSpendDashboardObservationStarted else { return }
        self.sharedSpendDashboardObservationStarted = true
        self.observeSharedSpendDashboardConfiguration()
    }

    func stopSharedSpendDashboardPublication() {
        self.sharedSpendDashboardObservationStarted = false
        self.sharedSpendDashboardControllerStorage?.stop()
        self.cancelSpendDashboardCodexCostCatchUp()
    }

    private func observeSharedSpendDashboardConfiguration() {
        guard self.sharedSpendDashboardObservationStarted else { return }
        let configuration = withObservationTracking {
            SpendDashboardSource.configuration(settings: self.settings, store: self)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSharedSpendDashboardConfiguration()
            }
        }
        // Provider-specific by design: Codex's multi-account 365-day scanner is the shared source producer.
        let codexRequests = configuration.providerIDs.contains(UsageProvider.codex.rawValue)
            ? SpendDashboardSource.codexRequests(settings: self.settings, store: self)
            : []
        self.synchronizeSpendDashboardCodexCostCatchUp(accounts: codexRequests)
        self.sharedSpendDashboardController().update(configuration: configuration)
    }
}

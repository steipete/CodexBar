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
        self.sharedSpendDashboardObservationDebounceTask?.cancel()
        self.sharedSpendDashboardObservationDebounceTask = nil
        self.sharedSpendDashboardTokenPublicationDebounceTask?.cancel()
        self.sharedSpendDashboardTokenPublicationDebounceTask = nil
        self.sharedSpendDashboardControllerStorage?.stop()
        self.cancelSpendDashboardCodexCostCatchUp()
    }

    private func observeSharedSpendDashboardConfiguration() {
        guard self.sharedSpendDashboardObservationStarted else { return }
        let configuration = withObservationTracking {
            SpendDashboardSource.configuration(settings: self.settings, store: self)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSharedSpendDashboardObservation()
            }
        }
        self.applySharedSpendDashboardConfiguration(configuration)
    }

    private func scheduleDebouncedSharedSpendDashboardObservation() {
        self.sharedSpendDashboardObservationDebounceTask?.cancel()
        let delay: Duration = self.startupBehavior.automaticallyStartsBackgroundWork
            ? .milliseconds(250) : .milliseconds(0)
        self.sharedSpendDashboardObservationDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sharedSpendDashboardObservationDebounceTask = nil
            self?.observeSharedSpendDashboardConfiguration()
        }
    }

    func synchronizeSharedSpendDashboardAfterTokenPublication(for provider: UsageProvider) {
        guard self.sharedSpendDashboardObservationStarted else { return }
        let isIndependent = Self.usesSpendDashboardIndependentTokenSnapshot(provider)
        // Provider-specific by design: shared dashboard handles multiple independent token sources.
        // Token publications both drive the shared dashboard.
        guard provider == .codex || isIndependent else { return }
        self.scheduleDebouncedTokenPublicationSync()
    }

    #if DEBUG
    var _test_hasPendingSpendDashboardTokenPublicationSync: Bool {
        self.sharedSpendDashboardTokenPublicationDebounceTask != nil
    }
    #endif

    private func scheduleDebouncedTokenPublicationSync() {
        self.sharedSpendDashboardTokenPublicationDebounceTask?.cancel()
        let delay: Duration = self.startupBehavior.automaticallyStartsBackgroundWork
            ? .milliseconds(250) : .milliseconds(0)
        self.sharedSpendDashboardTokenPublicationDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sharedSpendDashboardTokenPublicationDebounceTask = nil
            guard let self, self.sharedSpendDashboardObservationStarted else { return }
            self.applySharedSpendDashboardConfiguration(
                SpendDashboardSource.configuration(settings: self.settings, store: self))
        }
    }

    private func applySharedSpendDashboardConfiguration(_ configuration: SpendDashboardConfiguration) {
        // Provider-specific by design: Codex's multi-account 365-day scanner is the shared source producer.
        let codexRequests = configuration.providerIDs.contains(UsageProvider.codex.rawValue)
            ? SpendDashboardSource.codexRequests(settings: self.settings, store: self)
            : []
        self.synchronizeSpendDashboardCodexCostCatchUp(accounts: codexRequests)
        self.sharedSpendDashboardController().update(configuration: configuration)
    }
}

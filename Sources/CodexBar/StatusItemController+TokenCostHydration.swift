import Observation

extension StatusItemController {
    func observeTokenCostMenuHydrationChanges() {
        withObservationTracking {
            _ = self.store.tokenSnapshots
            _ = self.store.tokenErrors
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeTokenCostMenuHydrationChanges()
                self.scheduleOpenMenuTokenCostHydrationRefreshIfNeeded()
            }
        }
    }

    private func scheduleOpenMenuTokenCostHydrationRefreshIfNeeded() {
        guard Self.menuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        self.tokenCostMenuHydrationRefreshTask?.cancel()
        self.tokenCostMenuHydrationRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.tokenCostMenuHydrationRefreshTask = nil
            guard !self.openMenus.isEmpty else { return }
            self.menuContentVersion &+= 1
            self.menuLogger.debug(
                "token cost menu hydration refresh",
                metadata: ["openMenus": "\(self.openMenus.count)"])
            self.refreshOpenMenusForTokenCostHydration()
        }
    }
}

import Observation

struct IconPerfRefreshCycleMetrics {
    var updateIconsCalls = 0
    var renderedCalls = 0
    var skippedCalls = 0
}

extension StatusItemController {
    func observeIconPerfRefreshCycleChanges() {
        withObservationTracking {
            _ = self.store.isRefreshing
            _ = self.settings.debugLogLevel
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeIconPerfRefreshCycleChanges()
                self.handleIconPerfRefreshCycleChange()
            }
        }
        self.handleIconPerfRefreshCycleChange()
    }

    func handleIconPerfRefreshCycleChange() {
        guard self.settings.isVerboseLoggingEnabled else {
            self.iconPerfRefreshCycleMetrics = nil
            self.iconPerfUpdatePassActive = false
            return
        }
        guard !self.store.isRefreshing else { return }
        self.logIconPerfRefreshCycleIfNeeded()
    }

    func beginIconPerfUpdatePass() {
        self.iconPerfUpdatePassActive = false
        guard self.settings.isVerboseLoggingEnabled, self.store.isRefreshing else { return }
        if self.iconPerfRefreshCycleMetrics == nil {
            self.iconPerfRefreshCycleMetrics = IconPerfRefreshCycleMetrics()
        }
        self.iconPerfRefreshCycleMetrics?.updateIconsCalls += 1
        self.iconPerfUpdatePassActive = true
    }

    func endIconPerfUpdatePass() {
        self.iconPerfUpdatePassActive = false
    }

    func noteIconPerfRender(skipped: Bool) {
        guard self.iconPerfUpdatePassActive else { return }
        if skipped {
            self.iconPerfRefreshCycleMetrics?.skippedCalls += 1
        } else {
            self.iconPerfRefreshCycleMetrics?.renderedCalls += 1
        }
    }

    func logIconPerfRefreshCycleIfNeeded() {
        guard let metrics = self.iconPerfRefreshCycleMetrics,
              metrics.updateIconsCalls > 0
        else {
            self.iconPerfRefreshCycleMetrics = nil
            return
        }
        let message = "[perf] refresh cycle: updateIcons() called \(metrics.updateIconsCalls) times "
            + "(\(metrics.renderedCalls) rendered, \(metrics.skippedCalls) skipped)"
        self.menuLogger.verbose(message)
        self.iconPerfRefreshCycleMetrics = nil
    }
}

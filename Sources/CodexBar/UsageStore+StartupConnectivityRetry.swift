import Foundation

extension UsageStore {
    enum StartupBehavior {
        case automatic
        case full
        case testing

        var automaticallyStartsBackgroundWork: Bool {
            switch self {
            case .automatic, .full:
                true
            case .testing:
                false
            }
        }

        func resolved(isRunningTests: Bool) -> StartupBehavior {
            switch self {
            case .automatic:
                isRunningTests ? .testing : .full
            case .full, .testing:
                self
            }
        }
    }

    func recordStartupConnectivityRetryableFailure(_ error: Error) {
        guard self.startupConnectivityRetryRefreshActive else { return }
        guard Self.isStartupConnectivityRetryableError(error) else { return }
        self.startupConnectivityRetryNeeded = true
    }

    func completeStartupConnectivityRetryPass(currentAttempt: Int) {
        guard self.startupConnectivityRetryNeeded else {
            self.cancelStartupConnectivityRetry()
            return
        }

        let nextAttempt = currentAttempt + 1
        guard let delay = Self.startupConnectivityRetryDelay(forAttempt: nextAttempt) else {
            self.cancelStartupConnectivityRetry()
            return
        }

        self.scheduleStartupConnectivityRetry(attempt: nextAttempt, delay: delay)
    }

    private func scheduleStartupConnectivityRetry(attempt: Int, delay: TimeInterval) {
        guard self.startupBehavior.automaticallyStartsBackgroundWork ||
            self._test_startupConnectivityRetryScheduled != nil ||
            self._test_startupConnectivityRetrySleepOverride != nil
        else {
            return
        }

        self.startupConnectivityRetryTask?.cancel()
        self._test_startupConnectivityRetryScheduled?(attempt, delay)
        self.startupConnectivityRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleepForStartupConnectivityRetry(delay)
                guard !Task.isCancelled else { return }
                await self.runRefresh(startupConnectivityRetryAttempt: attempt)
            } catch {
                return
            }
        }
    }

    private func cancelStartupConnectivityRetry() {
        self.startupConnectivityRetryTask?.cancel()
        self.startupConnectivityRetryTask = nil
    }

    private func sleepForStartupConnectivityRetry(_ delay: TimeInterval) async throws {
        if let override = self._test_startupConnectivityRetrySleepOverride {
            try await override(delay)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

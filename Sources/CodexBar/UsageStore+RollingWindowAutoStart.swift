import CodexBarCore
import Foundation

extension UsageStore {
    func scheduleRollingWindowAutoStartIfNeeded(
        provider: UsageProvider,
        previousSnapshot: UsageSnapshot?,
        currentProviderData: UsageSnapshot,
        now: Date = Date())
    {
        guard self.settings.rollingWindowAutoStartEnabled(provider: provider),
              !self.rollingWindowAutoStartRuntime.inFlight.contains(provider),
              let decision = RollingWindowAutoStartDecision.shouldStart(
                  provider: provider,
                  previous: previousSnapshot,
                  currentProviderData: currentProviderData,
                  now: now)
        else {
            return
        }

        if let attempted = self.rollingWindowAutoStartRuntime.attemptedResetAt[provider],
           abs(attempted.timeIntervalSince(decision.resetAt)) < 1
        {
            return
        }

        self.rollingWindowAutoStartRuntime.attemptedResetAt[provider] = decision.resetAt
        self.rollingWindowAutoStartRuntime.inFlight.insert(provider)
        self.rollingWindowAutoStartStatus[provider] = "Starting a new rolling window..."

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.rollingWindowAutoStartRuntime.inFlight.remove(provider)
            }

            do {
                let runner = self.rollingWindowAutoStartRuntime
                    .testRunnerOverride ?? SubprocessRollingWindowPingRunner()
                try await RollingWindowPingStarter.start(
                    provider: provider,
                    environment: self.environmentBase,
                    runner: runner)
                self.rollingWindowAutoStartStatus[provider] = "Ping prompt sent."
                await self.refreshProvider(provider, coalesceIfRefreshing: true)
            } catch {
                self.rollingWindowAutoStartStatus[provider] = error.localizedDescription
                self.providerLogger.warning(
                    "Rolling window auto-start failed",
                    metadata: [
                        "provider": provider.rawValue,
                        "error": error.localizedDescription,
                    ])
            }
        }
    }
}

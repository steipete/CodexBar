import CodexBarCore
import Foundation

extension UsageStore {
    private static let rollingWindowAutoStartSameResetTolerance: TimeInterval = 1

    func resetRollingWindowAutoStartState(for provider: UsageProvider) {
        self.rollingWindowAutoStartStatus.removeValue(forKey: provider)
        self.rollingWindowAutoStartRuntime.inFlight.remove(provider)
        self.rollingWindowAutoStartRuntime.attemptedResetAt.removeValue(forKey: provider)
    }

    @MainActor
    func scheduleRollingWindowAutoStartIfNeeded(
        provider: UsageProvider,
        previousSourceLabel: String?,
        sourceLabel: String?,
        previousSnapshot: UsageSnapshot?,
        currentProviderData: UsageSnapshot,
        now: Date = Date())
    {
        guard self.settings.rollingWindowAutoStartEnabled(provider: provider),
              !self.rollingWindowAutoStartRuntime.inFlight.contains(provider),
              let decision = RollingWindowAutoStartDecision.shouldStart(
                  provider: provider,
                  previousSourceLabel: previousSourceLabel,
                  sourceLabel: sourceLabel,
                  previous: previousSnapshot,
                  currentProviderData: currentProviderData,
                  now: now)
        else {
            return
        }

        if let attempted = self.rollingWindowAutoStartRuntime.attemptedResetAt[provider],
           // Reset timestamps can be rounded differently across adjacent snapshots.
           abs(attempted.timeIntervalSince(decision.resetAt)) < Self.rollingWindowAutoStartSameResetTolerance
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
                #if DEBUG
                let runner = self.rollingWindowAutoStartRuntime
                    .testRunnerOverride ?? SubprocessRollingWindowPingRunner()
                #else
                let runner = SubprocessRollingWindowPingRunner()
                #endif
                let environment = ProviderRegistry.makeEnvironment(
                    base: self.environmentBase,
                    provider: provider,
                    settings: self.settings,
                    tokenOverride: nil)
                try await RollingWindowPingStarter.start(
                    provider: provider,
                    environment: environment,
                    runner: runner)
                self.rollingWindowAutoStartStatus[provider] = "Ping prompt sent."
                await self.refreshProvider(provider, coalesceIfRefreshing: true)
                let refreshedWindow = self.snapshots[provider].flatMap {
                    RollingWindowAutoStartSupport.rollingWindow(provider: provider, snapshot: $0)
                }
                if let resetsAt = refreshedWindow?.resetsAt, resetsAt > Date() {
                    self.rollingWindowAutoStartStatus.removeValue(forKey: provider)
                }
            } catch {
                self.rollingWindowAutoStartRuntime.attemptedResetAt.removeValue(forKey: provider)
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

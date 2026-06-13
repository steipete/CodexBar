import CodexBarCore
import Foundation

extension UsageStore {
    private static let rollingWindowAutoStartSameResetTolerance: TimeInterval = 1

    func resetRollingWindowAutoStartState(for provider: UsageProvider) {
        self.rollingWindowAutoStartStatus.removeValue(forKey: provider)
        self.rollingWindowAutoStartRuntime.inFlight = self.rollingWindowAutoStartRuntime.inFlight
            .filter { $0.provider != provider }
        self.rollingWindowAutoStartRuntime.attemptedResetAt = self.rollingWindowAutoStartRuntime.attemptedResetAt
            .filter { $0.key.provider != provider }
    }

    @MainActor
    func scheduleRollingWindowAutoStartIfNeeded(
        provider: UsageProvider,
        previousSourceLabel: String?,
        sourceLabel: String?,
        previousSnapshot: UsageSnapshot?,
        currentProviderData: UsageSnapshot,
        tokenOverride: TokenAccountOverride? = nil,
        codexActiveSourceOverride: CodexActiveSource? = nil,
        now: Date = Date())
    {
        let resolvedCodexActiveSource = provider == .codex
            ? (codexActiveSourceOverride ?? self.settings.codexResolvedActiveSource)
            : nil
        let route = Self.rollingWindowAutoStartRoute(
            provider: provider,
            codexActiveSource: resolvedCodexActiveSource)
        guard self.settings.rollingWindowAutoStartEnabled(provider: provider),
              self.canRouteRollingWindowAutoStart(provider: provider, tokenOverride: tokenOverride),
              !self.rollingWindowAutoStartRuntime.inFlight.contains(route),
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

        if let attempted = self.rollingWindowAutoStartRuntime.attemptedResetAt[route],
           // Reset timestamps can be rounded differently across adjacent snapshots.
           abs(attempted.timeIntervalSince(decision.resetAt)) < Self.rollingWindowAutoStartSameResetTolerance
        {
            return
        }

        self.rollingWindowAutoStartRuntime.attemptedResetAt[route] = decision.resetAt
        self.rollingWindowAutoStartRuntime.inFlight.insert(route)
        self.rollingWindowAutoStartStatus[provider] = "Starting a new rolling window..."

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.rollingWindowAutoStartRuntime.inFlight.remove(route)
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
                    tokenOverride: nil,
                    codexActiveSourceOverride: resolvedCodexActiveSource)
                try await RollingWindowPingStarter.start(
                    provider: provider,
                    environment: environment,
                    runner: runner)
                self.rollingWindowAutoStartStatus[provider] = "Ping prompt sent."
                await self.refreshProvider(provider)
                let refreshedWindow = self.snapshots[provider].flatMap {
                    RollingWindowAutoStartSupport.rollingWindow(provider: provider, snapshot: $0)
                }
                if let resetsAt = refreshedWindow?.resetsAt, resetsAt > Date() {
                    self.rollingWindowAutoStartStatus.removeValue(forKey: provider)
                }
            } catch {
                self.rollingWindowAutoStartRuntime.attemptedResetAt.removeValue(forKey: route)
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

    private static func rollingWindowAutoStartRoute(
        provider: UsageProvider,
        codexActiveSource: CodexActiveSource?) -> RollingWindowAutoStartRoute
    {
        guard provider == .codex else {
            return .provider(provider)
        }

        switch codexActiveSource {
        case .liveSystem:
            return .codexLiveSystem
        case let .managedAccount(id):
            return .codexManagedAccount(id)
        case nil:
            preconditionFailure("Codex rolling-window auto-start requires a resolved active source")
        }
    }

    private func canRouteRollingWindowAutoStart(
        provider: UsageProvider,
        tokenOverride: TokenAccountOverride?) -> Bool
    {
        tokenOverride == nil && self.settings.selectedTokenAccount(for: provider) == nil
    }
}

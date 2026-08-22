import CodexBarCore
import Foundation

struct CLIProxyAPIUsageCollectorState: Equatable {
    enum ConfigurationAvailability: Equatable {
        case unknown
        case available
        case unavailable
    }

    var configurationAvailability: ConfigurationAvailability = .unknown
    var configurationGeneration: String?
    var telemetryRevision: String?
}

@MainActor
extension UsageStore {
    private static let cliProxyAPIUsageCollectionInterval: Duration = .seconds(30)
    private static let cliProxyAPIPendingPruneInterval: Duration = .seconds(24 * 60 * 60)

    func startCLIProxyAPIUsageCollector(
        initialConfigurationGeneration: String? = nil,
        collectionInterval: Duration? = nil,
        pendingPruneInterval: Duration? = nil,
        failedPruneRetryInterval: Duration? = nil,
        maintenance: (@Sendable () -> Bool)? = nil,
        collector: (@Sendable () async -> CLIProxyAPIUsageCollectionResult)? = nil)
    {
        self.stopCLIProxyAPIUsageCollector()
        self.cliProxyAPICleanupRetryTask?.cancel()
        self.cliProxyAPICleanupRetryTask = nil
        let collectionInterval = collectionInterval ?? Self.cliProxyAPIUsageCollectionInterval
        let pendingPruneInterval = pendingPruneInterval ?? Self.cliProxyAPIPendingPruneInterval
        let failedPruneRetryInterval = failedPruneRetryInterval ?? Self.cliProxyAPIUsageCollectionInterval
        let maintenance = maintenance ?? {
            CLIProxyAPIUsageCollector.pruneExpiredUsage()
        }
        let initialConfigurationGeneration = initialConfigurationGeneration ??
            CostUsageCacheLocations.cliProxyAPIConfigurationGeneration()
        self.cliProxyAPIUsageCollectorTask = Task.detached(priority: .utility) { [weak self] in
            var nextPendingPruneAt: ContinuousClock.Instant?
            var collectorState = CLIProxyAPIUsageCollectorState(
                configurationGeneration: initialConfigurationGeneration,
                telemetryRevision: CLIProxyAPIUsageTelemetryRevision.current())
            while !Task.isCancelled {
                let now = ContinuousClock.now
                if nextPendingPruneAt.map({ now >= $0 }) ?? true {
                    let retryDelay = maintenance() ? pendingPruneInterval : failedPruneRetryInterval
                    nextPendingPruneAt = now.advanced(by: retryDelay)
                }
                guard let result = await self?.collectCLIProxyAPIUsageNow(collector: collector) else { return }
                collectorState = await self?.handleCLIProxyAPIUsageCollectionResult(
                    result,
                    collectorState: collectorState) ?? collectorState
                do {
                    try await Task.sleep(for: collectionInterval)
                } catch {
                    return
                }
            }
        }
    }

    @discardableResult
    func stopCLIProxyAPIUsageCollector() -> Task<Void, Never>? {
        let task = self.cliProxyAPIUsageCollectorTask
        task?.cancel()
        self.cliProxyAPIUsageCollectorTask = nil
        return task
    }

    @discardableResult
    func removeCLIProxyAPIConfiguration(
        remove: (() async -> CLIProxyAPIConfigurationRemovalResult)? = nil,
        scheduleCleanupRetry: (() -> Void)? = nil,
        refresh: ((UsageProvider, Bool) async -> Void)? = nil) async
        -> CLIProxyAPIConfigurationRemovalResult
    {
        let collectorTask = self.stopCLIProxyAPIUsageCollector()
        self.cliProxyAPICleanupRetryTask?.cancel()
        self.cliProxyAPICleanupRetryTask = nil
        await collectorTask?.value
        let result = if let remove {
            await remove()
        } else {
            await Task.detached(priority: .utility) {
                CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry()
            }.value
        }
        if result != .configurationRemovalFailed {
            self.invalidateCLIProxyAPICostAttribution(widgetReason: "cliproxyapi-disconnected")
            await self.refreshCLIProxyAPIAffectedProviders(refresh: refresh)
        }
        if result == .telemetryCleanupFailed {
            if let scheduleCleanupRetry {
                scheduleCleanupRetry()
            } else {
                self.startCLIProxyAPICleanupRetry()
            }
        }
        return result
    }

    @discardableResult
    func startCLIProxyAPICleanupRetry(
        retryInterval: Duration = .seconds(30),
        maintenance: @escaping @Sendable () -> Bool = {
            CLIProxyAPIUsageCollector.pruneExpiredUsage()
        }) -> Task<Void, Never>
    {
        self.cliProxyAPICleanupRetryTask?.cancel()
        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if maintenance() { return }
                do {
                    try await Task.sleep(for: retryInterval)
                } catch {
                    return
                }
            }
        }
        self.cliProxyAPICleanupRetryTask = task
        return task
    }

    func collectCLIProxyAPIUsageNow(
        collector: (@Sendable () async -> CLIProxyAPIUsageCollectionResult)? = nil) async
        -> CLIProxyAPIUsageCollectionResult
    {
        guard self.settings.costUsageEnabled else { return .disabled }
        if let collector {
            return await collector()
        }
        return await CLIProxyAPIUsageCollector.collect(shouldContinue: { [weak self] in
            await self?.settings.costUsageEnabled == true
        })
    }

    func handleCLIProxyAPIUsageCollectionResult(
        _ result: CLIProxyAPIUsageCollectionResult,
        collectorState: CLIProxyAPIUsageCollectorState,
        isExplicitlyDisconnected: () -> Bool = {
            CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected()
        },
        configurationGeneration: () -> String? = {
            CostUsageCacheLocations.cliProxyAPIConfigurationGeneration()
        },
        telemetryRevision: () -> String? = {
            CLIProxyAPIUsageTelemetryRevision.current()
        },
        refresh: ((UsageProvider, Bool) async -> Void)? = nil) async -> CLIProxyAPIUsageCollectorState
    {
        var collectorState = collectorState
        switch result {
        case .notConfigured:
            if collectorState.configurationAvailability == .available ||
                (collectorState.configurationAvailability == .unknown && isExplicitlyDisconnected())
            {
                self.invalidateCLIProxyAPICostAttribution(widgetReason: "cliproxyapi-disconnected")
            }
            collectorState.configurationAvailability = .unavailable
            collectorState.configurationGeneration = configurationGeneration()
            collectorState.telemetryRevision = telemetryRevision()
        case let .collected(count):
            let currentGeneration = configurationGeneration()
            let currentTelemetryRevision = telemetryRevision()
            if count > 0 ||
                collectorState.configurationAvailability == .unavailable ||
                (collectorState.configurationGeneration != nil &&
                    collectorState.configurationGeneration != currentGeneration) ||
                collectorState.telemetryRevision != currentTelemetryRevision
            {
                await self.refreshCLIProxyAPICostAttribution(refresh: refresh)
            }
            collectorState.configurationAvailability = .available
            collectorState.configurationGeneration = currentGeneration
            collectorState.telemetryRevision = currentTelemetryRevision
        case .failed:
            let currentGeneration = configurationGeneration()
            let currentTelemetryRevision = telemetryRevision()
            let configurationChanged = collectorState.configurationGeneration != nil &&
                collectorState.configurationGeneration != currentGeneration
            if collectorState.telemetryRevision != currentTelemetryRevision {
                await self.refreshCLIProxyAPICostAttribution(refresh: refresh)
            } else if configurationChanged {
                self.invalidateCLIProxyAPICostAttribution(widgetReason: "cliproxyapi-configuration-changed")
            }
            if configurationChanged {
                collectorState.configurationAvailability = .unavailable
                collectorState.configurationGeneration = currentGeneration
            }
            collectorState.telemetryRevision = currentTelemetryRevision
        case .disabled:
            break
        }
        return collectorState
    }

    func refreshCLIProxyAPICostAttribution(
        refresh: ((UsageProvider, Bool) async -> Void)? = nil) async
    {
        self.invalidateCLIProxyAPICostAttribution(widgetReason: "cliproxyapi-reconnected")
        await self.refreshCLIProxyAPIAffectedProviders(refresh: refresh)
    }

    private func refreshCLIProxyAPIAffectedProviders(
        refresh: ((UsageProvider, Bool) async -> Void)?) async
    {
        // Provider-specific by design: connection changes can affect both sides of the Codex/Claude attribution split.
        for provider in [UsageProvider.claude, .codex] {
            if let refresh {
                await refresh(provider, true)
            } else {
                await self.refreshTokenUsageNow(for: provider, force: true)
            }
        }
    }
}

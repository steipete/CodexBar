import CodexBarCore
import CryptoKit
import Foundation
import Observation

// swiftlint:disable file_length

struct SpendDashboardConfiguration: Equatable, Sendable {
    let costUsageEnabled: Bool
    let preferredCurrencyCode: String
    let providerIDs: [String]
    let codexAccountIdentities: [String]
    let codexAccountDisplayNames: [String: String]
    let cliProxyAPIConfigurationGeneration: String?
    let sourceOwnershipFingerprints: [String]
    let sourceRevisions: [String]
    let bucketTimeZoneIdentifier: String
    let openCodexUsageLogsEnabled: Bool
    let hideNativeCodexCostWhenOpenCodexPresent: Bool
    let hiddenSourceIDs: [String]
    let menuOwnershipFingerprint: String

    init(
        costUsageEnabled: Bool,
        preferredCurrencyCode: String = "auto",
        providerIDs: [String],
        codexAccountIdentities: [String],
        codexAccountDisplayNames: [String: String] = [:],
        cliProxyAPIConfigurationGeneration: String? = nil,
        sourceOwnershipFingerprints: [String] = [],
        sourceRevisions: [String] = [],
        bucketTimeZoneIdentifier: String = "",
        openCodexUsageLogsEnabled: Bool = false,
        hideNativeCodexCostWhenOpenCodexPresent: Bool = false,
        hiddenSourceIDs: [String] = [],
        menuOwnershipFingerprint: String = "")
    {
        self.costUsageEnabled = costUsageEnabled
        self.preferredCurrencyCode = preferredCurrencyCode
        self.providerIDs = providerIDs
        self.codexAccountIdentities = codexAccountIdentities
        self.codexAccountDisplayNames = codexAccountDisplayNames
        self.cliProxyAPIConfigurationGeneration = cliProxyAPIConfigurationGeneration
        self.sourceOwnershipFingerprints = sourceOwnershipFingerprints
        self.sourceRevisions = sourceRevisions
        self.bucketTimeZoneIdentifier = bucketTimeZoneIdentifier
        self.openCodexUsageLogsEnabled = openCodexUsageLogsEnabled
        self.hideNativeCodexCostWhenOpenCodexPresent = hideNativeCodexCostWhenOpenCodexPresent
        self.hiddenSourceIDs = hiddenSourceIDs
        self.menuOwnershipFingerprint = menuOwnershipFingerprint
    }

    var bucketCalendar: Calendar {
        CostUsageBucketTimeZone.calendar(identifier: self.bucketTimeZoneIdentifier)
    }
}

struct CodexSpendScanRequest: Equatable, Sendable {
    let id: String
    let displayName: String
    let source: CodexActiveSource
    let homePath: String
    let authFingerprint: String?
    let authFileWasReadable: Bool
    let cacheIdentity: String
}

struct CodexSpendSourceDescriptor: Sendable {
    let identity: String
    let displayName: String
    let request: CodexSpendScanRequest?
}

enum SpendDashboardRequestBuildMode: Equatable, Sendable {
    case refreshMissing
    case forceRefresh
    case captureOnly

    var forcesLoader: Bool {
        self == .forceRefresh
    }

    func shouldRefresh(hasPublication: Bool) -> Bool {
        switch self {
        case .refreshMissing: !hasPublication
        case .forceRefresh: true
        case .captureOnly: false
        }
    }
}

struct SpendDashboardLoadRequest: Sendable {
    let configuration: SpendDashboardConfiguration
    let capturedInputs: [SpendDashboardModel.ProviderInput]
    let unavailableSourceIDs: Set<String>
    let confirmedEmptySourceIDs: Set<String>
    let codexRequests: [CodexSpendScanRequest]
    let now: Date
    let force: Bool

    init(
        configuration: SpendDashboardConfiguration,
        capturedInputs: [SpendDashboardModel.ProviderInput],
        unavailableSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String> = [],
        codexRequests: [CodexSpendScanRequest],
        now: Date,
        force: Bool)
    {
        self.configuration = configuration
        self.capturedInputs = capturedInputs
        self.unavailableSourceIDs = unavailableSourceIDs
        self.confirmedEmptySourceIDs = confirmedEmptySourceIDs
        self.codexRequests = codexRequests
        self.now = now
        self.force = force
    }
}

struct SpendDashboardLoadResult: Sendable {
    enum OpenCodexObservation: Sendable, Equatable {
        case disabled
        case available
        case confirmedEmpty
        case unavailable
    }

    let inputs: [SpendDashboardModel.ProviderInput]
    let failedSourceIDs: Set<String>
    let invalidatedSourceIDs: Set<String>
    let openCodexObservation: OpenCodexObservation

    init(
        inputs: [SpendDashboardModel.ProviderInput],
        failedSourceIDs: Set<String>,
        invalidatedSourceIDs: Set<String> = [],
        openCodexObservation: OpenCodexObservation = .disabled)
    {
        self.inputs = inputs
        self.failedSourceIDs = failedSourceIDs
        self.invalidatedSourceIDs = invalidatedSourceIDs
        self.openCodexObservation = openCodexObservation
    }

    var failedSourceCount: Int {
        self.failedSourceIDs.count
    }
}

struct CodexSpendSnapshotLoadContext: Sendable {
    let account: CodexSpendScanRequest
    let cacheRoot: URL
    let now: Date
    let force: Bool
    let historyDays: Int
    let refreshPricingInBackground: Bool
    let includePiSessions: Bool
    let calendar: Calendar
}

struct CodexProxySpendSnapshotLoadContext: Sendable {
    let now: Date
    let force: Bool
    let historyDays: Int
    let refreshPricingInBackground: Bool
    let calendar: Calendar
}

enum SpendDashboardSource {
    typealias CodexSnapshotLoader = @Sendable (CodexSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot
    typealias CodexActivityLoader = @Sendable (CodexSpendSnapshotLoadContext) async
        -> CostUsageTokenActivityCache?
    typealias CodexProxySnapshotLoader = @Sendable (CodexProxySpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot
    typealias CachedCodexSnapshotLoader = @Sendable (CodexSpendSnapshotLoadContext) async
        -> CostUsageTokenSnapshot?
    typealias CodexCacheRootResolver = @Sendable (CodexSpendScanRequest) -> URL

    static let activityDays = 365
    /// Local spend scan window. Matches token-activity depth so 7d / 30d / All share one snapshot.
    static let scanDays = activityDays
    static let codexProxySourceID = "codex:cliproxyapi"
    private static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["TESTING_LIBRARY_VERSION"] != nil
            || environment["SWIFT_TESTING"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    @MainActor
    static func configuration(settings: SettingsStore, store: UsageStore) -> SpendDashboardConfiguration {
        store.discardSpendDashboardTokenPublicationsIfCostUsageDisabled()
        let providers = self.costCapableProviders(store: store)
        let codexSources = providers.contains(.codex)
            ? self.codexSources(settings: settings, store: store)
            : []
        return self.configuration(
            settings: settings,
            store: store,
            providers: providers,
            codexSources: codexSources)
    }

    @MainActor
    private static func configuration(
        settings: SettingsStore,
        store: UsageStore,
        providers: [UsageProvider],
        codexSources: [CodexSpendSourceDescriptor]) -> SpendDashboardConfiguration
    {
        var codexDisplayNames = self.codexDisplayNamesByID(codexSources)
        // Provider-specific by design: CLIProxyAPI is exposed as a synthetic source in the Codex spend family.
        if providers.contains(.codex) {
            let providerName = store.metadata(for: .codex).displayName
            codexDisplayNames[Self.codexProxySourceID] = "\(providerName) · CLIProxyAPI"
        }
        return SpendDashboardConfiguration(
            costUsageEnabled: self.spendCollectionEnabled(settings: settings, providers: providers),
            preferredCurrencyCode: settings.preferredCurrencyCode,
            providerIDs: providers.map(\.rawValue),
            codexAccountIdentities: codexSources.map(\.identity),
            codexAccountDisplayNames: codexDisplayNames,
            cliProxyAPIConfigurationGeneration: self.shouldLoadCodexProxy(
                providerIDs: providers.map(\.rawValue))
                ? CostUsageCacheLocations.cliProxyAPIConfigurationGeneration()
                : nil,
            sourceOwnershipFingerprints: self.sourceOwnershipFingerprints(
                providers: providers,
                settings: settings,
                store: store),
            sourceRevisions: self.sourceRevisions(providers: providers, settings: settings, store: store),
            bucketTimeZoneIdentifier: settings.costUsageBucketTimeZoneIdentifier,
            openCodexUsageLogsEnabled: settings.openCodexUsageLogsEnabled,
            hideNativeCodexCostWhenOpenCodexPresent: settings.hideNativeCodexCostWhenOpenCodexPresent,
            hiddenSourceIDs: settings.spendDashboardHiddenSourceIDs,
            menuOwnershipFingerprint: self.menuOwnershipFingerprint(
                settings: settings,
                providers: providers))
    }

    @MainActor
    static func makeRequest(
        settings: SettingsStore,
        store: UsageStore,
        mode: SpendDashboardRequestBuildMode,
        now: Date? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }) async -> SpendDashboardLoadRequest
    {
        store.discardSpendDashboardTokenPublicationsIfCostUsageDisabled()
        let initialProviders = self.costCapableProviders(store: store)
        guard self.spendCollectionEnabled(settings: settings, providers: initialProviders) else {
            return SpendDashboardLoadRequest(
                configuration: self.configuration(settings: settings, store: store),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: now ?? nowProvider(),
                force: mode.forcesLoader)
        }

        let providerBaselines = initialProviders.filter { $0 != .codex }.map { provider in
            let captured = self.capturedTokenPublication(store: store, provider: provider)
            return (
                provider: provider,
                publication: captured.publication,
                publicationRevision: captured.revision)
        }
        let baselinesToRefresh = providerBaselines.filter { mode.shouldRefresh(hasPublication: $0.publication != nil) }
        if !baselinesToRefresh.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for baseline in baselinesToRefresh {
                    group.addTask {
                        if UsageStore.tokenCostRequiresProviderSnapshot(baseline.provider) {
                            await store.refreshProvider(baseline.provider)
                        } else {
                            await store.refreshSpendDashboardTokenUsageNow(for: baseline.provider, force: true)
                        }
                    }
                }
            }
        }

        // A later provider refresh can suspend while an earlier provider publishes again.
        // Capture every provider only after all refresh work finishes so the request owns the
        // newest same-scope publication available at this boundary.
        let captureNow = now ?? nowProvider()
        let providers = self.costCapableProviders(store: store)
        // Provider-specific by design: spend dashboard
        let codexSources = providers.contains(.codex)
            ? self.codexSources(settings: settings, store: store)
            : []
        let codexRequests = codexSources.compactMap(\.request)
        let configuration = self.configuration(
            settings: settings,
            store: store,
            providers: providers,
            codexSources: codexSources)
        guard configuration.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: configuration,
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: captureNow,
                force: mode.forcesLoader)
        }

        var inputs: [SpendDashboardModel.ProviderInput] = []
        var unavailableSourceIDs: Set<String> = []
        var confirmedEmptySourceIDs: Set<String> = []
        // Provider-specific by design: spend dashboard
        for provider in providers where provider != .codex {
            // Provider-specific by design: Grok local session tokens are independent of the
            // remote billing snapshot, so a failed probe still publishes readable logs.
            if provider == .grok {
                if let snapshot = store.tokenSnapshot(
                    fromProviderSnapshot: store.snapshot(for: .grok),
                    provider: .grok,
                    historyDays: Self.scanDays)
                {
                    inputs.append(SpendDashboardModel.ProviderInput(
                        provider: .grok,
                        displayName: store.metadata(for: .grok).displayName,
                        snapshot: snapshot))
                } else {
                    confirmedEmptySourceIDs.insert(UsageProvider.grok.rawValue)
                }
                continue
            }
            guard let baseline = providerBaselines.first(where: { $0.provider == provider }) else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            let shouldRefresh = mode.shouldRefresh(hasPublication: baseline.publication != nil)
            let current = self.capturedTokenPublication(store: store, provider: provider)
            guard let currentPublication = current.publication else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            if shouldRefresh, baseline.publicationRevision == current.revision {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            guard let snapshot = self.dashboardTokenSnapshot(
                store: store,
                provider: provider,
                publication: currentPublication)
            else {
                confirmedEmptySourceIDs.insert(provider.rawValue)
                continue
            }
            inputs.append(SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: store.metadata(for: provider).displayName,
                snapshot: snapshot))
        }
        return SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: inputs,
            unavailableSourceIDs: unavailableSourceIDs,
            confirmedEmptySourceIDs: confirmedEmptySourceIDs,
            codexRequests: codexRequests,
            now: captureNow,
            force: mode.forcesLoader)
    }

    static func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        let codexProxySnapshotLoader: CodexProxySnapshotLoader? = if self.isRunningTests {
            nil
        } else {
            self.loadCodexProxySnapshot
        }
        return await self.load(
            request,
            cacheRootResolver: { self.codexCacheRoot(for: $0) },
            codexSnapshotLoader: { context in try await self.loadCodexSnapshot(context) },
            codexActivityLoader: { context in await self.loadCodexActivity(context) },
            codexProxySnapshotLoader: codexProxySnapshotLoader)
    }

    static func load(
        _ request: SpendDashboardLoadRequest,
        cacheRootResolver: @escaping CodexCacheRootResolver,
        codexSnapshotLoader: @escaping CodexSnapshotLoader) async -> SpendDashboardLoadResult
    {
        await self.load(
            request,
            cacheRootResolver: cacheRootResolver,
            codexSnapshotLoader: codexSnapshotLoader,
            codexActivityLoader: { context in await self.loadCodexActivity(context) },
            codexProxySnapshotLoader: nil)
    }

    static func loadCached(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        await self.loadCached(request, cacheRootResolver: { self.codexCacheRoot(for: $0) })
    }

    static func loadCached(
        _ request: SpendDashboardLoadRequest,
        cacheRootResolver: @escaping CodexCacheRootResolver) async -> SpendDashboardLoadResult
    {
        await self.loadCached(
            request,
            cacheRootResolver: cacheRootResolver,
            cachedCodexSnapshotLoader: { context in
                await CostUsageFetcher(cacheRoot: context.cacheRoot, calendar: context.calendar)
                    .loadCachedCodexTokenSnapshotForScopedHome(
                        now: context.now,
                        codexHomePath: context.account.homePath,
                        historyDays: context.historyDays,
                        includePiSessions: false,
                        includeProjectAndSessionBreakdowns: true,
                        calendar: context.calendar)
            })
    }

    static func loadCached(
        _ request: SpendDashboardLoadRequest,
        cachedCodexSnapshotLoader: CachedCodexSnapshotLoader) async -> SpendDashboardLoadResult
    {
        await self.loadCached(
            request,
            cacheRootResolver: { self.codexCacheRoot(for: $0) },
            cachedCodexSnapshotLoader: cachedCodexSnapshotLoader)
    }

    private static func loadCached(
        _ request: SpendDashboardLoadRequest,
        cacheRootResolver: CodexCacheRootResolver,
        cachedCodexSnapshotLoader: CachedCodexSnapshotLoader) async -> SpendDashboardLoadResult
    {
        var inputs = request.capturedInputs
        for account in request.codexRequests {
            guard !Task.isCancelled,
                  self.currentAuthFingerprint(for: account) == account.authFingerprint
            else { continue }
            let snapshot = await cachedCodexSnapshotLoader(self.snapshotContext(
                account: account,
                cacheRoot: cacheRootResolver(account),
                request: request,
                force: false,
                historyDays: Self.scanDays))
            guard !Task.isCancelled,
                  let snapshot,
                  self.currentAuthFingerprint(for: account) == account.authFingerprint
            else { continue }
            inputs.append(SpendDashboardModel.ProviderInput(
                id: "codex:\(account.id)",
                provider: .codex,
                displayName: account.displayName,
                modelProviderName: ProviderDescriptorRegistry.descriptor(for: .codex).metadata.displayName,
                snapshot: snapshot))
        }
        let openCodex = self.mergingOpenCodexInputsWithObservation(inputs, request: request)
        return SpendDashboardLoadResult(
            inputs: openCodex.inputs,
            failedSourceIDs: request.unavailableSourceIDs,
            openCodexObservation: openCodex.observation)
    }

    static func load(
        _ request: SpendDashboardLoadRequest,
        codexSnapshotLoader: @escaping CodexSnapshotLoader) async -> SpendDashboardLoadResult
    {
        await self.load(
            request,
            cacheRootResolver: { self.codexCacheRoot(for: $0) },
            codexSnapshotLoader: codexSnapshotLoader,
            codexActivityLoader: { _ in nil },
            codexProxySnapshotLoader: nil)
    }

    static func load(
        _ request: SpendDashboardLoadRequest,
        codexSnapshotLoader: @escaping CodexSnapshotLoader,
        codexActivityLoader: @escaping CodexActivityLoader) async -> SpendDashboardLoadResult
    {
        await self.load(
            request,
            cacheRootResolver: { self.codexCacheRoot(for: $0) },
            codexSnapshotLoader: codexSnapshotLoader,
            codexActivityLoader: codexActivityLoader,
            codexProxySnapshotLoader: nil)
    }

    static func load(
        _ request: SpendDashboardLoadRequest,
        codexSnapshotLoader: @escaping CodexSnapshotLoader,
        codexProxySnapshotLoader: CodexProxySnapshotLoader?) async -> SpendDashboardLoadResult
    {
        await self.load(
            request,
            cacheRootResolver: { self.codexCacheRoot(for: $0) },
            codexSnapshotLoader: codexSnapshotLoader,
            codexActivityLoader: { _ in nil },
            codexProxySnapshotLoader: codexProxySnapshotLoader)
    }

    private static func load(
        _ request: SpendDashboardLoadRequest,
        cacheRootResolver: @escaping CodexCacheRootResolver,
        codexSnapshotLoader: @escaping CodexSnapshotLoader,
        codexActivityLoader: @escaping CodexActivityLoader,
        codexProxySnapshotLoader: CodexProxySnapshotLoader?) async -> SpendDashboardLoadResult
    {
        var inputs = request.capturedInputs
        var failedSourceIDs = request.unavailableSourceIDs
        var invalidatedSourceIDs: Set<String> = []
        if !request.codexRequests.isEmpty {
            var pendingAccounts: [CodexSpendScanRequest] = []
            for account in request.codexRequests {
                let sourceID = "codex:\(account.id)"
                if !self.codexAuthFingerprintMatches(account) {
                    failedSourceIDs.insert(sourceID)
                    invalidatedSourceIDs.insert(sourceID)
                } else {
                    pendingAccounts.append(account)
                }
            }
            if !pendingAccounts.isEmpty {
                do {
                    try await withThrowingTaskGroup(of: (Int, String, SpendDashboardModel.ProviderInput?)
                        .self)
                    { group in
                        for (index, account) in pendingAccounts.enumerated() {
                            group.addTask {
                                let sourceID = "codex:\(account.id)"
                                do {
                                    let cacheRoot = cacheRootResolver(account)
                                    let snapshot = try await codexSnapshotLoader(self.snapshotContext(
                                        account: account,
                                        cacheRoot: cacheRoot,
                                        request: request,
                                        force: request.force,
                                        historyDays: Self.scanDays))
                                    try Task.checkCancellation()
                                    let tokenActivityCache = await codexActivityLoader(self.snapshotContext(
                                        account: account,
                                        cacheRoot: cacheRoot,
                                        request: request,
                                        force: false,
                                        historyDays: Self.activityDays))
                                    try Task.checkCancellation()
                                    guard self.codexAuthFingerprintMatches(account)
                                    else { return (index, sourceID, nil) }
                                    let input = SpendDashboardModel.ProviderInput(
                                        id: sourceID,
                                        provider: .codex,
                                        displayName: account.displayName,
                                        // Provider-specific by design: spend dashboard
                                        modelProviderName: ProviderDescriptorRegistry.descriptor(for: .codex)
                                            .metadata
                                            .displayName,
                                        snapshot: snapshot,
                                        tokenActivityCache: tokenActivityCache)
                                    return (index, sourceID, input)
                                } catch is CancellationError { throw CancellationError() } catch {
                                    return (index, "codex:\(account.id)", nil)
                                }
                            }
                        }
                        var results: [(Int, String, SpendDashboardModel.ProviderInput?)] = []
                        for try await result in group {
                            results.append(result)
                        }
                        results.sort { $0.0 < $1.0 }
                        for (_, sourceID, input) in results {
                            if let input {
                                inputs.append(input)
                            } else {
                                // Distinguish invalidated (auth changed) vs plain failure by re-checking.
                                if !self.codexAuthFingerprintMatches(
                                    pendingAccounts.first { sourceID == "codex:\($0.id)" }!)
                                {
                                    failedSourceIDs.insert(sourceID)
                                    invalidatedSourceIDs.insert(sourceID)
                                } else {
                                    failedSourceIDs.insert(sourceID)
                                }
                            }
                        }
                    }
                } catch is CancellationError {
                    failedSourceIDs.formUnion(request.codexRequests.map { "codex:\($0.id)" })
                    return SpendDashboardLoadResult(
                        inputs: [],
                        failedSourceIDs: failedSourceIDs,
                        invalidatedSourceIDs: invalidatedSourceIDs)
                } catch {}
            }
        }
        if self.shouldLoadCodexProxy(providerIDs: request.configuration.providerIDs),
           let codexProxySnapshotLoader
        {
            do {
                let snapshot = try await codexProxySnapshotLoader(CodexProxySpendSnapshotLoadContext(
                    now: request.now,
                    force: request.force,
                    historyDays: Self.scanDays,
                    refreshPricingInBackground: false,
                    calendar: request.configuration.bucketCalendar))
                try Task.checkCancellation()
                if !snapshot.daily.isEmpty {
                    // Provider-specific by design: proxy-attributed Claude rows are published in the Codex family.
                    let providerName = ProviderDescriptorRegistry.descriptor(for: .codex).metadata.displayName
                    inputs.append(SpendDashboardModel.ProviderInput(
                        id: Self.codexProxySourceID,
                        provider: .codex,
                        displayName: "\(providerName) · CLIProxyAPI",
                        modelProviderName: providerName,
                        snapshot: snapshot))
                }
            } catch is CancellationError {
                inputs.removeAll { $0.id == Self.codexProxySourceID }
                failedSourceIDs.insert(Self.codexProxySourceID)
                invalidatedSourceIDs.insert(Self.codexProxySourceID)
                return SpendDashboardLoadResult(
                    inputs: inputs,
                    failedSourceIDs: failedSourceIDs,
                    invalidatedSourceIDs: invalidatedSourceIDs)
            } catch {
                failedSourceIDs.insert(Self.codexProxySourceID)
            }
        }
        let lateInvalidatedSourceIDs = Set(request.codexRequests.compactMap { account in
            self.codexAuthFingerprintMatches(account)
                ? nil
                : "codex:\(account.id)"
        })
        failedSourceIDs.formUnion(lateInvalidatedSourceIDs)
        invalidatedSourceIDs.formUnion(lateInvalidatedSourceIDs)
        inputs.removeAll { lateInvalidatedSourceIDs.contains($0.id) }
        let openCodex = self.mergingOpenCodexInputsWithObservation(inputs, request: request)
        return SpendDashboardLoadResult(
            inputs: openCodex.inputs,
            failedSourceIDs: failedSourceIDs,
            invalidatedSourceIDs: invalidatedSourceIDs,
            openCodexObservation: openCodex.observation)
    }

    private static func snapshotContext(
        account: CodexSpendScanRequest,
        cacheRoot: URL,
        request: SpendDashboardLoadRequest,
        force: Bool,
        historyDays: Int) -> CodexSpendSnapshotLoadContext
    {
        CodexSpendSnapshotLoadContext(
            account: account,
            cacheRoot: cacheRoot,
            now: request.now,
            force: force,
            historyDays: historyDays,
            refreshPricingInBackground: false,
            includePiSessions: false,
            calendar: request.configuration.bucketCalendar)
    }

    private static func loadCodexSnapshot(
        _ context: CodexSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot
    {
        // Provider-specific by design: each managed Codex home receives an isolated transcript scan.
        try await CostUsageFetcher(cacheRoot: context.cacheRoot, calendar: context.calendar).loadTokenSnapshot(
            provider: .codex,
            environment: CodexHomeScope.scopedEnvironment(base: [:], codexHome: context.account.homePath),
            now: context.now,
            forceRefresh: context.force,
            codexHomePath: context.account.homePath,
            historyDays: context.historyDays,
            refreshPricingInBackground: context.refreshPricingInBackground,
            includePiSessions: context.includePiSessions,
            includeClaudeProxyUsage: false)
    }

    private static func loadCodexProxySnapshot(
        _ context: CodexProxySpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher(calendar: context.calendar).loadCodexProxyTokenSnapshot(
            now: context.now,
            forceRefresh: context.force,
            historyDays: context.historyDays,
            refreshPricingInBackground: context.refreshPricingInBackground)
    }

    static func shouldLoadCodexProxy(providerIDs: [String]) -> Bool {
        // Provider-specific by design: proxy attribution can affect both the Codex and Claude spend projections.
        providerIDs.contains(UsageProvider.codex.rawValue)
            || providerIDs.contains(UsageProvider.claude.rawValue)
    }

    private static func loadCodexActivity(
        _ context: CodexSpendSnapshotLoadContext) async -> CostUsageTokenActivityCache?
    {
        await CostUsageFetcher(cacheRoot: context.cacheRoot, calendar: context.calendar).loadCachedCodexTokenActivity(
            now: context.now,
            codexHomePath: context.account.homePath,
            maximumDays: context.historyDays)
    }

    @MainActor
    static func costCapableProviders(store: UsageStore) -> [UsageProvider] {
        store.enabledFirstPartyProvidersForDisplay().filter {
            store.settings.isCostUsageEffectivelyEnabled(for: $0)
        }
    }

    @MainActor
    private static func spendCollectionEnabled(
        settings: SettingsStore,
        providers: [UsageProvider]) -> Bool
    {
        settings.costUsageEnabled ||
            // Provider-specific by design: spend dashboard
            (providers.contains(.codex) && settings.codexLocalSessionCostLedgerEnabled)
    }

    @MainActor
    static func codexRequests(settings: SettingsStore, store: UsageStore) -> [CodexSpendScanRequest] {
        self.codexSources(settings: settings, store: store).compactMap(\.request)
    }

    @MainActor
    static func codexSources(settings: SettingsStore, store: UsageStore) -> [CodexSpendSourceDescriptor] {
        let accounts = settings.codexVisibleAccountProjection.visibleAccounts
        let providerName = store.metadata(for: .codex).displayName
        return accounts.enumerated().map { index, account in
            let homePath: String? = switch account.selectionSource {
            case .liveSystem:
                settings.liveSystemCodexHomePath(forActiveSource: .liveSystem)
            case let .managedAccount(id):
                settings.managedCodexRemoteHomePath(forActiveSource: .managedAccount(id: id))
            case let .profileHome(path):
                settings.profileCodexHomePath(forActiveSource: .profileHome(path: path))
            }
            let request = self.codexRequest(
                account: account,
                homePath: homePath,
                providerName: providerName,
                index: index,
                count: accounts.count,
                bucketTimeZoneIdentifier: settings.costUsageBucketTimeZoneIdentifier)
            let cacheIdentity = request?.cacheIdentity ?? self.sha256([
                account.id,
                self.sourceToken(account.selectionSource),
                CodexHomeScope.normalizedHomePath(homePath) ?? "unavailable-home",
                CodexAuthFingerprint.normalize(account.authFingerprint) ?? "missing-auth",
                settings.costUsageBucketTimeZoneIdentifier,
            ].joined(separator: "\u{0}"))
            let displayName = request?.displayName ?? self.codexDisplayName(
                providerName: providerName,
                index: index,
                count: accounts.count)
            return CodexSpendSourceDescriptor(
                identity: "\(account.id)|\(cacheIdentity)",
                displayName: displayName,
                request: request)
        }
    }

    @MainActor
    static func currentMenuOwnershipFingerprint(settings: SettingsStore, store: UsageStore) -> String {
        self.menuOwnershipFingerprint(
            settings: settings,
            providers: self.costCapableProviders(store: store))
    }

    @MainActor
    private static func menuOwnershipFingerprint(
        settings: SettingsStore,
        providers: [UsageProvider]) -> String
    {
        var parts = providers.map { provider in
            "\(provider.rawValue):\(settings.providerConfigRevision(for: provider))"
        }
        parts.append("bucket:\(settings.costUsageBucketTimeZoneIdentifier)")
        if providers.contains(.codex) {
            parts.append(contentsOf: settings.codexVisibleAccountProjection.visibleAccounts.map { account in
                let homePath: String? = switch account.selectionSource {
                case .liveSystem:
                    settings.liveSystemCodexHomePath(forActiveSource: .liveSystem)
                case let .managedAccount(id):
                    settings.managedCodexRemoteHomePath(forActiveSource: .managedAccount(id: id))
                case let .profileHome(path):
                    settings.profileCodexHomePath(forActiveSource: .profileHome(path: path))
                }
                return [
                    account.id,
                    self.sourceToken(account.selectionSource),
                    CodexHomeScope.normalizedHomePath(homePath) ?? "unavailable-home",
                ].joined(separator: "|")
            })
        }
        return self.sha256(parts.joined(separator: "\u{0}"))
    }

    @MainActor
    private static func sourceRevisions(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageStore) -> [String]
    {
        var revisions: [String] = []
        // Provider-specific by design: regular Codex publication is a refresh trigger; account caches remain authority.
        if providers.contains(.codex) {
            revisions.append("codex-dashboard:\(store.spendDashboardCodexCostCatchUpRevision)")
            revisions.append("codex-current:\(store.tokenSnapshotPublicationRevision(for: .codex))")
        }
        if settings.openCodexUsageLogsEnabled {
            revisions.append("opencodex:\(settings.costUsageSettingsRevision)")
        }
        revisions += providers.compactMap { provider in
            // Provider-specific by design: Codex inputs come from account caches, not provider-global snapshots.
            guard provider != .codex else { return nil }
            let current: CurrentProviderConfigTokenPublication? =
                if UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider) {
                    store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider)
                } else {
                    store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
                }
            guard let current else { return "\(provider.rawValue):unavailable" }
            guard let snapshot = current.snapshot else {
                return "\(provider.rawValue):empty:\(current.publicationRevision)"
            }
            return "\(provider.rawValue):snapshot:\(current.publicationRevision):\(self.snapshotRevision(snapshot))"
        }
        return revisions
    }

    private static func snapshotRevision(_ snapshot: CostUsageTokenSnapshot) -> String {
        var encoder = SpendDashboardSnapshotRevisionEncoder()
        encoder.append(snapshot.currencyCode)
        encoder.append(snapshot.historyDays)
        encoder.append(snapshot.historyCoverageIsEstablished)
        encoder.append(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        encoder.append(snapshot.last30DaysTokens)
        encoder.append(snapshot.last30DaysCostUSD)
        encoder.append(snapshot.daily.count)
        for entry in snapshot.daily {
            encoder.append(entry.date)
            encoder.append(entry.inputTokens)
            encoder.append(entry.cacheReadTokens)
            encoder.append(entry.cacheCreationTokens)
            encoder.append(entry.outputTokens)
            encoder.append(entry.totalTokens)
            encoder.append(entry.requestCount)
            encoder.append(entry.costUSD)
            encoder.append(entry.modelBreakdowns?.count)
            for breakdown in entry.modelBreakdowns ?? [] {
                encoder.append(breakdown.modelName)
                encoder.append(breakdown.attribution?.client.rawValue ?? "")
                encoder.append(breakdown.attribution?.route.rawValue ?? "")
                encoder.append(breakdown.attribution?.modelProvider.rawValue ?? "")
                encoder.append(breakdown.attribution?.upstream?.provider ?? "")
                encoder.append(breakdown.attribution?.upstream?.authType.rawValue ?? "")
                encoder.append(breakdown.attribution?.upstream?.model ?? "")
                encoder.append(breakdown.attribution?.upstream?.executorType ?? "")
                for evidence in breakdown.attribution?.evidence ?? [] {
                    encoder.append(evidence.rawValue)
                }
                encoder.append(breakdown.totalTokens)
                encoder.append(breakdown.requestCount)
                encoder.append(breakdown.costUSD)
                encoder.append(breakdown.standardCostUSD)
                encoder.append(breakdown.priorityCostUSD)
                encoder.append(breakdown.standardTokens)
                encoder.append(breakdown.priorityTokens)
            }
        }
        return encoder.finalize()
    }

    @MainActor
    private static func sourceOwnershipFingerprints(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageStore) -> [String]
    {
        providers.compactMap { provider in
            // Provider-specific by design: Codex ownership is represented by account-scoped source fingerprints.
            guard provider != .codex else { return nil }
            var config = settings.providerConfig(for: provider) ?? ProviderConfig(id: provider.instanceID)
            config.enabled = nil
            config.quotaWarnings = nil
            // The dashboard follows the effective account, not the whole saved-account collection.
            // Inactive-account edits must not invalidate visible spend for the selected account.
            config.tokenAccounts = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = (try? encoder.encode(config)) ?? Data()
            let scope = UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider)
                ? store.spendDashboardTokenSnapshotScopeSignature(for: provider)
                : store.tokenSnapshotScopeSignature(for: provider)
            let accountOwnership = settings.effectiveSelectedTokenAccount(for: provider)
                .map { store.tokenAccountSnapshotCacheKey(provider: provider, account: $0) }
                ?? "ambient"
            return "\(provider.rawValue):\(self.sha256(encoded)):\(self.sha256(scope)):" +
                self.sha256("\(accountOwnership)\u{0}\(settings.costUsageBucketTimeZoneIdentifier)")
        }
    }

    @MainActor
    private static func dashboardTokenSnapshot(
        store: UsageStore,
        provider: UsageProvider,
        publication: CurrentProviderConfigTokenPublication) -> CostUsageTokenSnapshot?
    {
        // Provider-specific by design: Grok's catalog input is the local session scan, even when
        // the remote billing snapshot is missing.
        if provider == .grok {
            return store.tokenSnapshot(
                fromProviderSnapshot: store.snapshot(for: .grok),
                provider: .grok,
                historyDays: self.scanDays)
        }
        if UsageStore.tokenCostRequiresProviderSnapshot(provider),
           let usage = store.snapshot(for: provider.instanceID),
           let derived = store.tokenSnapshot(
               fromProviderSnapshot: usage,
               provider: provider,
               historyDays: scanDays)
        {
            return derived
        }
        return publication.snapshot
    }

    @MainActor
    private static func capturedTokenPublication(
        store: UsageStore,
        provider: UsageProvider) -> (
        publication: CurrentProviderConfigTokenPublication?,
        revision: UInt64)
    {
        if UsageStore.usesSpendDashboardIndependentTokenSnapshot(provider) {
            let revision = store.spendDashboardTokenSnapshotPublicationRevision(for: provider)
            if let spend = store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider) {
                return (spend, revision)
            }
            return (
                store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
                revision)
        }
        return (
            store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
            store.tokenSnapshotPublicationRevision(for: provider))
    }

    static func codexRequest(
        account: CodexVisibleAccount,
        homePath: String?,
        providerName: String,
        index: Int,
        count: Int,
        bucketTimeZoneIdentifier: String = "") -> CodexSpendScanRequest?
    {
        guard let homePath = CodexHomeScope.normalizedHomePath(homePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: homePath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: homePath)
        else { return nil }
        let sourceToken = self.sourceToken(account.selectionSource)
        let liveAuthFingerprint = CodexAuthFingerprint.fingerprint(homePath: homePath)
        let authFingerprint = liveAuthFingerprint
            ?? CodexAuthFingerprint.normalize(account.authFingerprint)
        let cacheIdentity = self.sha256([
            account.id,
            sourceToken,
            homePath,
            authFingerprint ?? "missing-auth",
            bucketTimeZoneIdentifier,
        ].joined(separator: "\u{0}"))
        let displayName = self.codexDisplayName(providerName: providerName, index: index, count: count)
        return CodexSpendScanRequest(
            id: account.id,
            displayName: displayName,
            source: account.selectionSource,
            homePath: homePath,
            authFingerprint: authFingerprint,
            authFileWasReadable: liveAuthFingerprint != nil,
            cacheIdentity: cacheIdentity)
    }

    private static func codexDisplayName(providerName: String, index: Int, count: Int) -> String {
        count == 1
            ? providerName
            : "\(providerName) · #\(codexBarLocalizedInteger(index + 1))"
    }

    private static func codexDisplayNamesByID(_ sources: [CodexSpendSourceDescriptor]) -> [String: String] {
        sources.reduce(into: [:]) { result, source in
            guard let separator = source.identity.lastIndex(of: "|") else { return }
            result["codex:\(source.identity[..<separator])"] = source.displayName
        }
    }

    private static func sourceToken(_ source: CodexActiveSource) -> String {
        switch source {
        case .liveSystem: "live"
        case let .managedAccount(id): "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path): "profile:\(path)"
        }
    }

    private static func sha256(_ value: String) -> String {
        self.sha256(Data(value.utf8))
    }

    private static func sha256(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    static func codexCacheRoot(for request: CodexSpendScanRequest) -> URL {
        let costUsageDirectory = UsageStore.costUsageCacheDirectory()
        if request.source == .liveSystem {
            return costUsageDirectory.deletingLastPathComponent()
        }
        return costUsageDirectory
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(request.cacheIdentity, isDirectory: true)
    }

    static func codexAuthFingerprintMatches(_ request: CodexSpendScanRequest) -> Bool {
        self.currentAuthFingerprint(for: request) == request.authFingerprint
    }

    private static func currentAuthFingerprint(for request: CodexSpendScanRequest) -> String? {
        let current = CodexAuthFingerprint.fingerprint(homePath: request.homePath)
        return request.authFileWasReadable ? current : current ?? request.authFingerprint
    }
}

private struct SpendDashboardSnapshotRevisionEncoder {
    private var hasher = SHA256()

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        self.append(UInt64(data.count))
        self.hasher.update(data: data)
    }

    mutating func append(_ value: Int) {
        self.append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Int?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func append(_ value: Bool) {
        self.appendPresence(value)
    }

    mutating func append(_ value: Double) {
        self.append(value.bitPattern)
    }

    mutating func append(_ value: Double?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func finalize() -> String {
        self.hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func appendPresence(_ isPresent: Bool) {
        var byte: UInt8 = isPresent ? 1 : 0
        withUnsafeBytes(of: &byte) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }

    private mutating func append(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }
}

@MainActor
@Observable
final class SpendDashboardController {
    typealias RequestBuilder = @MainActor @Sendable (SpendDashboardRequestBuildMode) async
        -> SpendDashboardLoadRequest
    typealias Loader = @Sendable (SpendDashboardLoadRequest) async -> SpendDashboardLoadResult
    typealias CachedLoader = @Sendable (SpendDashboardLoadRequest) async -> SpendDashboardLoadResult
    typealias PublicationHandler = @MainActor @Sendable (SpendDashboardPublication) -> Void

    private enum ReconciliationObservation: Sendable {
        case confirmedEmpty
        case confirmedNonempty(SpendDashboardModel.ProviderInput)
    }

    private struct ForcedOutcome: Sendable {
        let request: SpendDashboardLoadRequest
        let result: SpendDashboardLoadResult
        let invalidatedSourceIDs: Set<String>
        let observations: [String: ReconciliationObservation]

        func incorporating(capture: SpendDashboardLoadRequest) -> Self {
            var observations = self.observations
            for input in capture.capturedInputs {
                let forcedRevision = Self.sourceRevision(for: input.id, in: self.request.configuration)
                let captureRevision = Self.sourceRevision(for: input.id, in: capture.configuration)
                let hasNewerSourceRevision = forcedRevision != nil
                    && captureRevision != nil
                    && forcedRevision != captureRevision
                if self.result.failedSourceIDs.contains(input.id),
                   observations[input.id] == nil,
                   !hasNewerSourceRevision
                {
                    continue
                }
                observations[input.id] = .confirmedNonempty(input)
            }
            for sourceID in capture.confirmedEmptySourceIDs {
                observations[sourceID] = .confirmedEmpty
            }
            return Self(
                request: self.request,
                result: self.result,
                invalidatedSourceIDs: self.invalidatedSourceIDs,
                observations: observations)
        }

        private static func sourceRevision(
            for sourceID: String,
            in configuration: SpendDashboardConfiguration) -> String?
        {
            let prefix = "\(sourceID):"
            return configuration.sourceRevisions.first { $0.hasPrefix(prefix) }
        }

        var confirmedEmptySourceIDs: Set<String> {
            Set(self.observations.compactMap { sourceID, observation in
                guard case .confirmedEmpty = observation else { return nil }
                return sourceID
            })
        }

        var confirmedNonemptyInputs: [SpendDashboardModel.ProviderInput] {
            self.observations.sorted { $0.key < $1.key }.compactMap { _, observation in
                guard case let .confirmedNonempty(input) = observation else { return nil }
                return input
            }
        }
    }

    private struct ReconciledOutcome: Sendable {
        let result: SpendDashboardLoadResult
        let confirmedEmptySourceIDs: Set<String>
    }

    private enum LoadPhase: Sendable {
        case ordinary
        case forcing
        case reconciling(ForcedOutcome)

        var buildMode: SpendDashboardRequestBuildMode {
            switch self {
            case .ordinary: .refreshMissing
            case .forcing: .forceRefresh
            case .reconciling: .captureOnly
            }
        }

        var manualRefreshOutstanding: Bool {
            switch self {
            case .ordinary: false
            case .forcing, .reconciling: true
            }
        }
    }

    private(set) var model = SpendDashboardModel(requestedDays: 30, groups: [])
    private(set) var publication = SpendDashboardPublication.empty
    private(set) var isRefreshing = false
    private(set) var failedSourceCount = 0
    private(set) var generation: UInt64 = 0
    private(set) var configuration: SpendDashboardConfiguration?
    private(set) var selectedDays: Int
    private(set) var selectedDay: Date?

    private static let daysDefaultsKey = "settingsSpendDashboardDays"
    private let userDefaults: UserDefaults
    private let requestBuilder: RequestBuilder
    private let cachedLoader: CachedLoader?
    private let loader: Loader
    private let nowProvider: @Sendable () -> Date
    private let publicationHandler: PublicationHandler?
    private var loadTask: Task<Void, Never>?
    private var loadedInputs: [SpendDashboardModel.ProviderInput] = []
    private var loadedAt = Date()
    private var lastSuccessfulConfiguration: SpendDashboardConfiguration?
    private var phase = LoadPhase.ordinary
    // Throttle high-frequency date-window refreshes (didBecomeActive bursts).
    private var lastRefreshDateWindowAt: Date?
    private var lastRefreshDateWindowDayStart: Date?

    init(
        userDefaults: UserDefaults = .standard,
        requestBuilder: @escaping RequestBuilder,
        cachedLoader: CachedLoader? = nil,
        loader: @escaping Loader = SpendDashboardSource.load,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        publicationHandler: PublicationHandler? = nil)
    {
        self.userDefaults = userDefaults
        self.requestBuilder = requestBuilder
        self.cachedLoader = cachedLoader
        self.loader = loader
        self.nowProvider = nowProvider
        self.publicationHandler = publicationHandler
        self.selectedDays = Self.normalizedDays(userDefaults.integer(forKey: Self.daysDefaultsKey))
    }

    func update(configuration: SpendDashboardConfiguration, force: Bool = false) {
        self.refreshRetainedCodexDisplayNames(configuration.codexAccountDisplayNames)
        if force {
            self.configuration = configuration
            self.startLoad(configuration: configuration, phase: .forcing)
            return
        }
        guard configuration != self.configuration else { return }
        let previousConfiguration = self.configuration
        // Fast-path: display-only changes (filter, currency, hide flag) require
        // only a model rebuild — no Codex scan or token capture.
        if let previousConfiguration,
           Self.isDisplayOnlyConfigurationChange(from: previousConfiguration, to: configuration)
        {
            self.configuration = configuration
            self.rebuildModel()
            return
        }
        self.configuration = configuration
        if self.isRefreshing || self.phase.manualRefreshOutstanding,
           let previousConfiguration,
           Self.sameSourceOwnership(previousConfiguration, configuration)
        {
            // Same-owner revision churn during an in-flight load adopts the newer
            // configuration and lets the current pass finish once; handleBuiltRequest
            // reconciles any remaining drift after apply.
            self.publishCurrentState()
            return
        }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func startLoad(
        configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.generation &+= 1
        let generation = self.generation
        self.loadTask?.cancel()
        let invalidatedSourceIDs = switch phase {
        case let .reconciling(outcome): outcome.invalidatedSourceIDs
        case .ordinary, .forcing:
            Self.invalidatedSourceIDs(
                previous: self.lastSuccessfulConfiguration,
                current: configuration)
        }
        self.phase = phase

        if !invalidatedSourceIDs.isEmpty {
            self.loadedInputs.removeAll { invalidatedSourceIDs.contains($0.id) }
            self.failedSourceIDs.subtract(invalidatedSourceIDs)
            self.confirmedEmptySourceIDs.subtract(invalidatedSourceIDs)
            self.failedSourceCount = 0
            self.rebuildModel()
        }
        let shouldPrimeCachedCodex: Bool = if case .ordinary = phase {
            self.cachedLoader != nil && !Set(Self.codexOwnershipByID(configuration.codexAccountIdentities).keys)
                .isSubset(of: Set(self.loadedInputs.map(\.id)))
        } else {
            false
        }

        guard configuration.costUsageEnabled,
              !configuration.providerIDs.isEmpty || configuration.openCodexUsageLogsEnabled
        else {
            self.loadedInputs = []
            self.failedSourceIDs = []
            self.confirmedEmptySourceIDs = []
            self.openCodexObservation = .disabled
            self.failedSourceCount = 0
            self.isRefreshing = false
            self.lastSuccessfulConfiguration = configuration
            self.phase = .ordinary
            self.loadTask = nil
            self.rebuildModel()
            return
        }

        self.isRefreshing = true
        self.publishCurrentState()
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            if shouldPrimeCachedCodex, let cachedLoader = self.cachedLoader {
                let cachedRequest = await self.requestBuilder(.captureOnly)
                guard !Task.isCancelled,
                      generation == self.generation
                else { return }
                let cachedResult = await cachedLoader(cachedRequest)
                guard !Task.isCancelled,
                      generation == self.generation
                else { return }
                if cachedRequest.configuration == self.configuration {
                    self.applyCached(request: cachedRequest, result: cachedResult)
                }
            }
            let request = await self.requestBuilder(phase.buildMode)
            guard !Task.isCancelled,
                  generation == self.generation
            else { return }
            await self.handleBuiltRequest(
                request,
                startedWith: configuration,
                phase: phase,
                generation: generation,
                invalidatedSourceIDs: invalidatedSourceIDs)
        }
    }

    private func applyCached(
        request: SpendDashboardLoadRequest,
        result: SpendDashboardLoadResult)
    {
        let cachedIDs = Set(result.inputs.map(\.id))
        self.loadedInputs.removeAll { cachedIDs.contains($0.id) }
        self.loadedInputs.append(contentsOf: result.inputs)
        self.loadedInputs = Self.stableUniqueInputs(self.loadedInputs)
        self.loadedAt = request.now
        self.failedSourceCount = result.failedSourceCount
        self.failedSourceIDs = result.failedSourceIDs
        self.openCodexObservation = result.openCodexObservation
        self.refreshRetainedCodexDisplayNames(request.configuration.codexAccountDisplayNames)
        self.rebuildModel()
    }

    private func handleBuiltRequest(
        _ request: SpendDashboardLoadRequest,
        startedWith startConfiguration: SpendDashboardConfiguration,
        phase: LoadPhase,
        generation: UInt64,
        invalidatedSourceIDs: Set<String>) async
    {
        guard let targetConfiguration = self.configuration else { return }
        if case let .reconciling(outcome) = phase,
           !Self.sameSourceOwnership(outcome.request.configuration, targetConfiguration)
        {
            self.startLoad(configuration: targetConfiguration, phase: .forcing)
            return
        }
        guard Self.sameSourceOwnership(startConfiguration, targetConfiguration) else {
            self.restartAfterBuildMismatch(targetConfiguration, phase: phase)
            return
        }

        let phase: LoadPhase = if case let .reconciling(outcome) = phase,
                                  Self.sameSourceOwnership(request.configuration, targetConfiguration)
        {
            .reconciling(outcome.incorporating(capture: request))
        } else {
            phase
        }

        if request.configuration != targetConfiguration {
            if case .forcing = phase,
               Self.sameSourceOwnership(request.configuration, targetConfiguration)
            {
                // Same-owner revision churn does not justify another provider force. The forced
                // loader executes once; its mandatory capture barrier reconciles the latest token.
                if targetConfiguration == startConfiguration {
                    self.configuration = request.configuration
                }
            } else if targetConfiguration == startConfiguration,
                      Self.sameSourceOwnership(targetConfiguration, request.configuration)
            {
                // The request owns an atomic newer same-owner capture. Adopt it even when the
                // external observation callback has not delivered that revision yet.
                self.configuration = request.configuration
            } else {
                let nextConfiguration = targetConfiguration == startConfiguration
                    ? request.configuration
                    : targetConfiguration
                self.restartAfterBuildMismatch(nextConfiguration, phase: phase)
                return
            }
        }

        switch phase {
        case .ordinary:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard request.configuration == latestConfiguration else {
                self.startLoad(configuration: latestConfiguration, phase: .ordinary)
                return
            }
            self.apply(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                confirmedEmptySourceIDs: request.confirmedEmptySourceIDs)

        case .forcing:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard Self.sameSourceOwnership(request.configuration, latestConfiguration) else {
                self.startLoad(configuration: latestConfiguration, phase: .forcing)
                return
            }
            let outcome = ForcedOutcome(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                observations: Dictionary(uniqueKeysWithValues: request.confirmedEmptySourceIDs.map {
                    ($0, ReconciliationObservation.confirmedEmpty)
                }))
            self.startLoad(configuration: latestConfiguration, phase: .reconciling(outcome))

        case let .reconciling(outcome):
            let reconciled = Self.merge(outcome: outcome, capture: request)
            self.apply(
                request: request,
                result: reconciled.result,
                invalidatedSourceIDs: outcome.invalidatedSourceIDs,
                confirmedEmptySourceIDs: reconciled.confirmedEmptySourceIDs)
        }
    }

    private func restartAfterBuildMismatch(
        _ configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.configuration = configuration
        let nextPhase: LoadPhase = switch phase {
        case .ordinary: .ordinary
        case .forcing: .forcing
        case let .reconciling(outcome):
            Self.sameSourceOwnership(outcome.request.configuration, configuration)
                ? .reconciling(outcome)
                : .forcing
        }
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func apply(
        request: SpendDashboardLoadRequest,
        result: SpendDashboardLoadResult,
        invalidatedSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String>)
    {
        let codexDisplayNames = request.configuration.codexAccountDisplayNames
        self.refreshRetainedCodexDisplayNames(codexDisplayNames)
        var nextInputs = result.inputs
        if !result.failedSourceIDs.isEmpty {
            let freshIDs = Set(nextInputs.map(\.id))
            let unsafeSourceIDs = invalidatedSourceIDs
                .union(result.invalidatedSourceIDs)
                .union(confirmedEmptySourceIDs)
            nextInputs.append(contentsOf: self.loadedInputs.filter {
                result.failedSourceIDs.contains($0.id) &&
                    !unsafeSourceIDs.contains($0.id) &&
                    !freshIDs.contains($0.id)
            }.map { Self.relabelCodexInput($0, displayNamesByID: codexDisplayNames) })
        }
        self.configuration = request.configuration
        self.loadedInputs = Self.stableUniqueInputs(nextInputs)
        self.loadedAt = request.now
        self.lastSuccessfulConfiguration = request.configuration
        self.failedSourceCount = result.failedSourceCount
        self.failedSourceIDs = result.failedSourceIDs
        self.confirmedEmptySourceIDs = confirmedEmptySourceIDs
        self.openCodexObservation = result.openCodexObservation
        self.isRefreshing = false
        self.phase = .ordinary
        self.loadTask = nil
        self.rebuildModel()
    }

    private static func merge(
        outcome: ForcedOutcome,
        capture: SpendDashboardLoadRequest) -> ReconciledOutcome
    {
        let forceFailed = outcome.result.failedSourceIDs
        let invalidated = outcome.result.invalidatedSourceIDs
        let barrierFailed = capture.unavailableSourceIDs
        var forcedCodexIDs = Set(outcome.request.codexRequests.map { "codex:\($0.id)" })
        if SpendDashboardSource.shouldLoadCodexProxy(
            providerIDs: outcome.request.configuration.providerIDs)
        {
            forcedCodexIDs.insert(SpendDashboardSource.codexProxySourceID)
        }
        let confirmedNonemptyInputs = outcome.confirmedNonemptyInputs
        let confirmedNonemptyIDs = Set(confirmedNonemptyInputs.map(\.id))
        var inputs = capture.capturedInputs.filter {
            (!forceFailed.contains($0.id) || confirmedNonemptyIDs.contains($0.id)) &&
                !invalidated.contains($0.id) &&
                !outcome.confirmedEmptySourceIDs.contains($0.id)
        }
        var capturedIDs = Set(inputs.map(\.id))
        for input in confirmedNonemptyInputs
            where !capturedIDs.contains(input.id) && !invalidated.contains(input.id)
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        for input in outcome.result.inputs
            where !capturedIDs.contains(input.id) &&
            !forceFailed.contains(input.id) &&
            !invalidated.contains(input.id) &&
            !outcome.confirmedEmptySourceIDs.contains(input.id) &&
            (forcedCodexIDs.contains(input.id) || barrierFailed.contains(input.id))
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        let openCodex = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            inputs,
            request: outcome.request)
        return ReconciledOutcome(
            result: SpendDashboardLoadResult(
                inputs: openCodex.inputs,
                failedSourceIDs: forceFailed.union(barrierFailed),
                invalidatedSourceIDs: invalidated,
                openCodexObservation: openCodex.observation),
            confirmedEmptySourceIDs: outcome.confirmedEmptySourceIDs)
    }

    func refresh() {
        guard let configuration else { return }
        self.update(configuration: configuration, force: true)
    }

    func selectDays(_ days: Int) {
        let days = Self.normalizedDays(days)
        guard days != self.selectedDays else { return }
        self.selectedDays = days
        self.userDefaults.set(days, forKey: Self.daysDefaultsKey)
        self.rebuildModel(publish: false)
    }

    func selectDay(_ day: Date?) {
        let calendar = self.configuration?.bucketCalendar ?? .current
        let normalized = day.map { calendar.startOfDay(for: $0) }
        guard normalized != self.selectedDay else { return }
        self.selectedDay = normalized
        self.rebuildModel(publish: false)
    }

    func refreshDateWindow(now: Date? = nil) {
        let now = now ?? self.nowProvider()
        let calendar = self.configuration?.bucketCalendar ?? .current
        let previousDay = calendar.startOfDay(for: self.loadedAt)
        let nextDay = calendar.startOfDay(for: now)
        let isSameDay = previousDay == nextDay
        // Throttle burst activations (didBecomeActive) that otherwise rebuild
        // the 365-day model on every app focus. Keep a 30s floor for same-day
        // revisits while still allowing immediate refresh when the bucket day
        // actually rolled over or a previous load failed.
        if isSameDay,
           let lastAt = self.lastRefreshDateWindowAt,
           let lastDay = self.lastRefreshDateWindowDayStart,
           lastDay == nextDay,
           now.timeIntervalSince(lastAt) < 30,
           self.lastSuccessfulConfiguration != nil,
           self.failedSourceCount == 0
        {
            self.loadedAt = now
            return
        }
        self.lastRefreshDateWindowAt = now
        self.lastRefreshDateWindowDayStart = nextDay
        self.loadedAt = now
        self.rebuildModel()
        guard let configuration else { return }
        guard !isSameDay || self.lastSuccessfulConfiguration == nil || self.failedSourceCount > 0
        else { return }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    func stop() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.configuration = nil
        self.loadedInputs = []
        self.failedSourceIDs = []
        self.confirmedEmptySourceIDs = []
        self.openCodexObservation = .disabled
        self.isRefreshing = false
        self.phase = .ordinary
        self.lastRefreshDateWindowAt = nil
        self.lastRefreshDateWindowDayStart = nil
        self.publishCurrentState()
    }

    private func rebuildModel(publish: Bool = true) {
        let configuration = self.configuration
        self.model = SpendDashboardModel.build(
            inputs: self.loadedInputs,
            requestedDays: self.selectedDays,
            now: self.loadedAt,
            calendar: configuration?.bucketCalendar ?? .current,
            preferredCurrencyCode: configuration?.preferredCurrencyCode ?? "auto",
            hiddenSourceIDs: Set(configuration?.hiddenSourceIDs ?? []),
            hideNativeCodexWhenOpenCodexPresent: configuration?.hideNativeCodexCostWhenOpenCodexPresent ?? false,
            selectedDay: self.selectedDay)
        if publish {
            self.publishCurrentState()
        }
    }

    @ObservationIgnored private var failedSourceIDs: Set<String> = []
    @ObservationIgnored private var confirmedEmptySourceIDs: Set<String> = []
    @ObservationIgnored private var openCodexObservation: SpendDashboardLoadResult.OpenCodexObservation = .disabled
    @ObservationIgnored private var publicationRevision: UInt64 = 0

    private func publishCurrentState() {
        self.publicationRevision &+= 1
        let inputByID = Dictionary(uniqueKeysWithValues: self.loadedInputs.map { ($0.id, $0) })
        let sourceIDs = self.orderedSourceIDs(inputByID: inputByID)
        var sources = sourceIDs.compactMap { sourceID -> SpendSourcePublication? in
            let input = inputByID[sourceID]
            guard let provider = input?.provider ?? self.provider(for: sourceID) else { return nil }
            let state: SpendSourcePublication.State = if input != nil {
                self.failedSourceIDs.contains(sourceID) ? .staleLastKnown : .available
            } else if self.confirmedEmptySourceIDs.contains(sourceID) {
                .confirmedEmpty
            } else if self.isRefreshing {
                .loading
            } else {
                .unavailable
            }
            return SpendSourcePublication(
                id: sourceID,
                provider: provider,
                displayName: input?.displayName ?? self.displayName(for: sourceID, provider: provider),
                role: input?.sourceKind == .openCodex ? .enrichment : .subscription,
                state: state)
        }
        if self.configuration?.openCodexUsageLogsEnabled == true,
           !sources.contains(where: { $0.id == SpendDashboardModel.openCodexSourceID }),
           self.configuration?.hiddenSourceIDs.contains(SpendDashboardModel.openCodexSourceID) != true
        {
            let state: SpendSourcePublication.State = if self.isRefreshing {
                .loading
            } else {
                switch self.openCodexObservation {
                case .available: .available
                case .confirmedEmpty: .confirmedEmpty
                case .unavailable, .disabled: .unavailable
                }
            }
            sources.append(SpendSourcePublication(
                id: SpendDashboardModel.openCodexSourceID,
                // Provider-specific by design: OpenCodex enrichment maps to Codex provider
                provider: .codex,
                displayName: "OpenCodex",
                role: .enrichment,
                state: state))
        }
        let publication = SpendDashboardPublication(
            revision: self.publicationRevision,
            generation: self.generation,
            configuration: self.configuration,
            loadedAt: self.loadedAt,
            isRefreshing: self.isRefreshing,
            inputs: self.loadedInputs,
            sources: sources)
        self.publication = publication
        self.publicationHandler?(publication)
    }

    private static func stableUniqueInputs(
        _ inputs: [SpendDashboardModel.ProviderInput]) -> [SpendDashboardModel.ProviderInput]
    {
        var seen: Set<String> = []
        return inputs.filter { seen.insert($0.id).inserted }
    }

    private func orderedSourceIDs(
        inputByID: [String: SpendDashboardModel.ProviderInput]) -> [String]
    {
        var ids: [String] = []
        for providerID in self.configuration?.providerIDs ?? [] {
            if providerID == UsageProvider.codex.rawValue {
                ids.append(contentsOf: (self.configuration?.codexAccountIdentities ?? []).compactMap { identity in
                    guard let separator = identity.lastIndex(of: "|") else { return nil }
                    return "codex:\(identity[..<separator])"
                })
            } else {
                ids.append(providerID)
            }
        }
        ids.append(contentsOf: inputByID.keys.sorted())
        ids.append(contentsOf: self.confirmedEmptySourceIDs.sorted())
        ids.append(contentsOf: self.failedSourceIDs.sorted())
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private func provider(for sourceID: String) -> UsageProvider? {
        if sourceID.hasPrefix("codex:") { return .codex }
        return UsageProvider(rawValue: sourceID)
    }

    private func displayName(for sourceID: String, provider: UsageProvider) -> String {
        self.configuration?.codexAccountDisplayNames[sourceID]
            ?? ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    private func refreshRetainedCodexDisplayNames(_ displayNamesByID: [String: String]) {
        guard !displayNamesByID.isEmpty else { return }
        var didChange = false
        let relabeled = self.loadedInputs.map { input in
            let updated = Self.relabelCodexInput(input, displayNamesByID: displayNamesByID)
            didChange = didChange || updated.displayName != input.displayName
            return updated
        }
        guard didChange else { return }
        self.loadedInputs = relabeled
        self.rebuildModel()
    }

    private static func relabelCodexInput(
        _ input: SpendDashboardModel.ProviderInput,
        displayNamesByID: [String: String]) -> SpendDashboardModel.ProviderInput
    {
        // Provider-specific by design: spend dashboard
        guard input.provider == .codex,
              let displayName = displayNamesByID[input.id],
              displayName != input.displayName
        else { return input }
        return SpendDashboardModel.ProviderInput(
            id: input.id,
            provider: input.provider,
            displayName: displayName,
            modelProviderName: input.modelProviderName,
            snapshot: input.snapshot,
            tokenActivityCache: input.tokenActivityCache,
            sourceKind: input.sourceKind)
    }

    private static func sameSourceOwnership(
        _ lhs: SpendDashboardConfiguration,
        _ rhs: SpendDashboardConfiguration) -> Bool
    {
        lhs.costUsageEnabled == rhs.costUsageEnabled &&
            lhs.providerIDs == rhs.providerIDs &&
            lhs.codexAccountIdentities == rhs.codexAccountIdentities &&
            lhs.cliProxyAPIConfigurationGeneration == rhs.cliProxyAPIConfigurationGeneration &&
            lhs.sourceOwnershipFingerprints == rhs.sourceOwnershipFingerprints &&
            lhs.bucketTimeZoneIdentifier == rhs.bucketTimeZoneIdentifier &&
            lhs.openCodexUsageLogsEnabled == rhs.openCodexUsageLogsEnabled &&
            lhs.hideNativeCodexCostWhenOpenCodexPresent == rhs.hideNativeCodexCostWhenOpenCodexPresent &&
            lhs.hiddenSourceIDs == rhs.hiddenSourceIDs &&
            lhs.preferredCurrencyCode == rhs.preferredCurrencyCode
    }

    private static func isDisplayOnlyConfigurationChange(
        from lhs: SpendDashboardConfiguration,
        to rhs: SpendDashboardConfiguration) -> Bool
    {
        // Only presentation-layer fields changed; no provider scan or token capture needed.
        guard lhs.costUsageEnabled == rhs.costUsageEnabled,
              lhs.providerIDs == rhs.providerIDs,
              lhs.codexAccountIdentities == rhs.codexAccountIdentities,
              lhs.cliProxyAPIConfigurationGeneration == rhs.cliProxyAPIConfigurationGeneration,
              lhs.sourceOwnershipFingerprints == rhs.sourceOwnershipFingerprints,
              lhs.sourceRevisions == rhs.sourceRevisions,
              lhs.bucketTimeZoneIdentifier == rhs.bucketTimeZoneIdentifier,
              lhs.openCodexUsageLogsEnabled == rhs.openCodexUsageLogsEnabled
        else { return false }
        return lhs.hiddenSourceIDs != rhs.hiddenSourceIDs ||
            lhs.preferredCurrencyCode != rhs.preferredCurrencyCode ||
            lhs.hideNativeCodexCostWhenOpenCodexPresent != rhs.hideNativeCodexCostWhenOpenCodexPresent ||
            lhs.menuOwnershipFingerprint != rhs.menuOwnershipFingerprint ||
            lhs.codexAccountDisplayNames != rhs.codexAccountDisplayNames
    }

    private static func invalidatedSourceIDs(
        previous: SpendDashboardConfiguration?,
        current: SpendDashboardConfiguration) -> Set<String>
    {
        guard let previous else { return [] }
        let previousOwnership = self.sourceOwnershipByID(previous.sourceOwnershipFingerprints)
        let currentOwnership = self.sourceOwnershipByID(current.sourceOwnershipFingerprints)
        let providerIDs = Set(previousOwnership.keys).union(currentOwnership.keys)
        let changedProviderIDs = providerIDs.filter { previousOwnership[$0] != currentOwnership[$0] }

        let previousCodexOwnership = self.codexOwnershipByID(previous.codexAccountIdentities)
        let currentCodexOwnership = self.codexOwnershipByID(current.codexAccountIdentities)
        let codexIDs = Set(previousCodexOwnership.keys).union(currentCodexOwnership.keys)
        let changedCodexIDs = codexIDs.filter {
            previousCodexOwnership[$0] != currentCodexOwnership[$0]
        }
        var invalidatedSourceIDs = Set(changedProviderIDs).union(changedCodexIDs)
        if previous.cliProxyAPIConfigurationGeneration != current.cliProxyAPIConfigurationGeneration {
            invalidatedSourceIDs.insert(SpendDashboardSource.codexProxySourceID)
        }
        return invalidatedSourceIDs
    }

    private static func sourceOwnershipByID(_ fingerprints: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fingerprints.compactMap { fingerprint in
            guard let separator = fingerprint.firstIndex(of: ":") else { return nil }
            let sourceID = String(fingerprint[..<separator])
            guard !sourceID.isEmpty else { return nil }
            return (sourceID, fingerprint)
        })
    }

    private static func codexOwnershipByID(_ identities: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: identities.compactMap { identity in
            guard let separator = identity.lastIndex(of: "|") else { return nil }
            let accountID = String(identity[..<separator])
            guard !accountID.isEmpty else { return nil }
            return ("codex:\(accountID)", identity)
        })
    }

    private static let supportedDayRanges = [7, 30, 90, SpendDashboardSource.scanDays]

    private static func normalizedDays(_ value: Int) -> Int {
        self.supportedDayRanges.contains(value) ? value : 30
    }
}

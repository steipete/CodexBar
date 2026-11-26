import Foundation

extension CostUsageFetcher {
    struct VertexAITokenLoadContext: Sendable {
        let environment: [String: String]
        let now: Date
        let since: Date
        let historyDays: Int
        let forceRefresh: Bool
        let allowVertexClaudeFallback: Bool
        let bypassScannerDebounce: Bool
        let allowPricingRefresh: Bool
        let refreshPricingInBackground: Bool
        let scannerOptions: CostUsageScanner.Options
        let piOptions: PiSessionCostScanner.Options
        let modelsDevClient: ModelsDevClient
        let reportContext: CostUsageReportContext?
        let vertexAISettings: VertexAIProviderSettings
        let transport: (any ProviderHTTPTransport)?
    }

    static func loadVertexAITokenResult(context: VertexAITokenLoadContext) async throws -> CostUsageTokenResult {
        let settings = context.vertexAISettings
        let effectiveAllowFallback = context.allowVertexClaudeFallback || settings.allowClaudeFallback
        var scanOptions = context.scannerOptions
        Self.configureScannerRefresh(
            &scanOptions,
            provider: .vertexai,
            allowVertexClaudeFallback: effectiveAllowFallback,
            forceRefresh: context.forceRefresh,
            bypassScannerDebounce: context.bypassScannerDebounce)

        let calendar = scanOptions.calendar
        if context.allowPricingRefresh {
            if context.refreshPricingInBackground {
                let now = context.now
                let cacheRoot = scanOptions.cacheRoot
                let client = context.modelsDevClient
                Task.detached(priority: .utility) {
                    await ModelsDevPricingPipeline.refreshIfNeeded(
                        now: now,
                        cacheRoot: cacheRoot,
                        client: client)
                }
            } else {
                await ModelsDevPricingPipeline.refreshIfNeeded(
                    now: context.now,
                    cacheRoot: scanOptions.cacheRoot,
                    client: context.modelsDevClient)
            }
        }

        let localScanOptions = LocalTokenScanOptions(
            allowVertexClaudeFallback: effectiveAllowFallback,
            includePiSessions: false,
            shouldMergePiUsage: false,
            scanOptions: scanOptions,
            environment: context.environment,
            piOptions: context.piOptions,
            reportContext: context.reportContext)

        switch settings.telemetryCostSource {
        case .localClaudeLogsOnly:
            let localResult = try await Self.loadLocalTokenScanResult(
                provider: .vertexai,
                since: context.since,
                now: context.now,
                options: localScanOptions)
            let snapshot = Self.tokenSnapshot(
                from: localResult.inclusive.daily,
                now: context.now,
                historyDays: context.historyDays,
                calendar: calendar,
                historyCoverageIsEstablished: localResult.inclusive.historyCoverageIsEstablished,
                historyScanIsPartial: false,
                costProvenance: .listPriceEstimate,
                projects: localResult.inclusive.projects,
                sessions: localResult.inclusive.sessions,
                detailsAreComplete: localResult.inclusive.detailsAreComplete,
                updatedAt: localResult.inclusive.staleSnapshotUpdatedAt)
            return CostUsageTokenResult(snapshot: snapshot, accounting: nil)

        case .cloudMonitoringOnly:
            let cloudReport = try await Self.fetchVertexCloudServingReport(
                context: context,
                calendar: calendar,
                excludeAnthropicPublisher: false)
            guard let cloudReport else {
                return CostUsageTokenResult(
                    snapshot: Self.unavailableLocalSnapshot(
                        now: context.now,
                        historyDays: context.historyDays,
                        calendar: calendar),
                    accounting: nil)
            }
            let snapshot = Self.tokenSnapshot(
                from: cloudReport,
                now: context.now,
                historyDays: context.historyDays,
                calendar: calendar,
                historyCoverageIsEstablished: true,
                monetaryValuesAreAvailable: settings.estimateCloudCost,
                costProvenance: settings.estimateCloudCost ? .listPriceEstimate : .unknown,
                historyLabel: settings.estimateCloudCost
                    ? "Last \(context.historyDays) days (Cloud est.)"
                    : nil,
                projects: [],
                sessions: [],
                detailsAreComplete: true)
            return CostUsageTokenResult(snapshot: snapshot, accounting: nil)

        case .auto:
            let localResult = try await Self.loadLocalTokenScanResult(
                provider: .vertexai,
                since: context.since,
                now: context.now,
                options: localScanOptions)
            let hasLocalClaudeEntries = !localResult.inclusive.daily.data.isEmpty
            let cloudReport = try await Self.fetchVertexCloudServingReport(
                context: context,
                calendar: calendar,
                excludeAnthropicPublisher: hasLocalClaudeEntries)

            guard let cloudReport else {
                let snapshot = Self.tokenSnapshot(
                    from: localResult.inclusive.daily,
                    now: context.now,
                    historyDays: context.historyDays,
                    calendar: calendar,
                    historyCoverageIsEstablished: localResult.inclusive.historyCoverageIsEstablished,
                    historyScanIsPartial: false,
                    costProvenance: .listPriceEstimate,
                    projects: localResult.inclusive.projects,
                    sessions: localResult.inclusive.sessions,
                    detailsAreComplete: localResult.inclusive.detailsAreComplete,
                    updatedAt: localResult.inclusive.staleSnapshotUpdatedAt)
                return CostUsageTokenResult(snapshot: snapshot, accounting: nil)
            }

            if !hasLocalClaudeEntries {
                let snapshot = Self.tokenSnapshot(
                    from: cloudReport,
                    now: context.now,
                    historyDays: context.historyDays,
                    calendar: calendar,
                    historyCoverageIsEstablished: true,
                    monetaryValuesAreAvailable: settings.estimateCloudCost,
                    costProvenance: settings.estimateCloudCost ? .listPriceEstimate : .unknown,
                    historyLabel: settings.estimateCloudCost
                        ? "Last \(context.historyDays) days (Cloud est.)"
                        : nil,
                    projects: [],
                    sessions: [],
                    detailsAreComplete: true)
                return CostUsageTokenResult(snapshot: snapshot, accounting: nil)
            }

            let mergedDaily = CostUsageDailyReport.merged(
                [localResult.inclusive.daily, cloudReport],
                calendar: calendar)
            let hasMonetaryCosts = mergedDaily.data.contains { $0.costUSD != nil }
                || mergedDaily.summary?.totalCostUSD != nil
            let snapshot = Self.tokenSnapshot(
                from: mergedDaily,
                now: context.now,
                historyDays: context.historyDays,
                calendar: calendar,
                historyCoverageIsEstablished: localResult.inclusive.historyCoverageIsEstablished,
                monetaryValuesAreAvailable: hasMonetaryCosts,
                costProvenance: hasMonetaryCosts ? .listPriceEstimate : .unknown,
                historyLabel: settings.estimateCloudCost
                    ? "Last \(context.historyDays) days (Cloud + Local est.)"
                    : nil,
                projects: localResult.inclusive.projects,
                sessions: localResult.inclusive.sessions,
                detailsAreComplete: localResult.inclusive.detailsAreComplete,
                updatedAt: localResult.inclusive.staleSnapshotUpdatedAt)
            return CostUsageTokenResult(snapshot: snapshot, accounting: nil)
        }
    }

    private static func fetchVertexCloudServingReport(
        context: VertexAITokenLoadContext,
        calendar: Calendar,
        excludeAnthropicPublisher: Bool) async throws -> CostUsageDailyReport?
    {
        let transport = context.transport ?? ProviderHTTPClient.shared
        let credentials: VertexAIOAuthCredentials
        do {
            credentials = try await VertexAIOAuthCredentialsStore.resolveValidCredentials(
                environment: context.environment,
                projectIDOverride: context.vertexAISettings.projectIDOverride,
                refreshTransport: transport,
                persistRefreshed: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        let pricingResolver = CostUsagePricing.ClaudeResolver(
            now: context.now,
            cacheRoot: context.scannerOptions.cacheRoot)
        let queryOptions = VertexAIQueryOptions(
            locationFilter: context.vertexAISettings.regionFilter,
            baseModelFilter: context.vertexAISettings.modelFilter,
            includeOnlineServing: true,
            servingWindowDays: context.historyDays)

        do {
            return try await VertexAIUsageFetcher.fetchOnlineServingReport(
                accessToken: credentials.accessToken,
                projectId: credentials.projectId,
                config: VertexAIUsageFetcher.OnlineServingReportConfig(
                    since: context.since,
                    until: context.now,
                    calendar: calendar,
                    options: queryOptions,
                    estimateCost: context.vertexAISettings.estimateCloudCost,
                    excludeAnthropicPublisher: excludeAnthropicPublisher),
                pricingResolver: pricingResolver,
                transport: transport)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

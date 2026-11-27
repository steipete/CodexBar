import Foundation

extension CostUsageFetcher {
    struct VertexAITokenLoadContext: Sendable {
        @ProcessEnvironment private(set) var environment: [String: String]
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
            let cloudOutcome = try await Self.fetchVertexCloudServingReport(
                context: context,
                calendar: calendar)
            switch cloudOutcome {
            case .failed:
                return CostUsageTokenResult(
                    snapshot: Self.unavailableLocalSnapshot(
                        now: context.now,
                        historyDays: context.historyDays,
                        calendar: calendar),
                    accounting: nil)
            case .empty:
                return CostUsageTokenResult(
                    snapshot: Self.vertexCloudTokenSnapshot(
                        from: CostUsageDailyReport(data: [], summary: nil),
                        context: context,
                        calendar: calendar,
                        isPartial: false),
                    accounting: nil)
            case let .report(cloudReport, isPartial):
                return CostUsageTokenResult(
                    snapshot: Self.vertexCloudTokenSnapshot(
                        from: cloudReport,
                        context: context,
                        calendar: calendar,
                        isPartial: isPartial),
                    accounting: nil)
            }

        case .auto:
            return try await Self.loadAutoVertexAITokenResult(
                context: context,
                calendar: calendar,
                localScanOptions: localScanOptions)
        }
    }

    private static func loadAutoVertexAITokenResult(
        context: VertexAITokenLoadContext,
        calendar: Calendar,
        localScanOptions: LocalTokenScanOptions) async throws -> CostUsageTokenResult
    {
        let localResult: LocalTokenScanResult?
        do {
            localResult = try await Self.loadLocalTokenScanResult(
                provider: .vertexai,
                since: context.since,
                now: context.now,
                options: localScanOptions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            localResult = nil
        }
        let hasLocalClaudeEntries = !(localResult?.inclusive.daily.data.isEmpty ?? true)
        let cloudOutcome = try await Self.fetchVertexCloudServingReport(
            context: context,
            calendar: calendar)

        switch cloudOutcome {
        case .failed:
            guard let localResult, hasLocalClaudeEntries else {
                return CostUsageTokenResult(
                    snapshot: Self.unavailableLocalSnapshot(
                        now: context.now,
                        historyDays: context.historyDays,
                        calendar: calendar),
                    accounting: nil)
            }
            let snapshot = Self.tokenSnapshot(
                from: localResult.inclusive.daily,
                now: context.now,
                historyDays: context.historyDays,
                calendar: calendar,
                historyCoverageIsEstablished: localResult.inclusive.historyCoverageIsEstablished,
                historyScanIsPartial: true,
                costProvenance: .listPriceEstimate,
                projects: localResult.inclusive.projects,
                sessions: localResult.inclusive.sessions,
                detailsAreComplete: localResult.inclusive.detailsAreComplete,
                updatedAt: localResult.inclusive.staleSnapshotUpdatedAt)
            return CostUsageTokenResult(snapshot: snapshot, accounting: nil)

        case .empty:
            guard let localResult else {
                return CostUsageTokenResult(
                    snapshot: Self.vertexCloudTokenSnapshot(
                        from: CostUsageDailyReport(data: [], summary: nil),
                        context: context,
                        calendar: calendar,
                        isPartial: true,
                        detailsAreComplete: false),
                    accounting: nil)
            }
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

        case let .report(cloudReport, isPartial):
            // Keep Cloud Monitoring totals authoritative across all publishers (including Anthropic)
            // so remote, other-machine, or other-day traffic is never dropped when local Claude logs exist.
            // Local project/session breakdowns stay attached separately.
            return CostUsageTokenResult(
                snapshot: Self.vertexCloudTokenSnapshot(
                    from: cloudReport,
                    context: context,
                    calendar: calendar,
                    isPartial: isPartial,
                    projects: localResult?.inclusive.projects ?? [],
                    sessions: localResult?.inclusive.sessions ?? [],
                    detailsAreComplete: localResult?.inclusive.detailsAreComplete ?? false),
                accounting: nil)
        }
    }

    private static func vertexCloudTokenSnapshot(
        from cloudReport: CostUsageDailyReport,
        context: VertexAITokenLoadContext,
        calendar: Calendar,
        isPartial: Bool,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        detailsAreComplete: Bool = true) -> CostUsageTokenSnapshot
    {
        let estimateCloudCost = context.vertexAISettings.estimateCloudCost
        let hasMonetaryCosts = estimateCloudCost
            && (cloudReport.data.contains { $0.costUSD != nil } || cloudReport.summary?.totalCostUSD != nil)
        return Self.tokenSnapshot(
            from: cloudReport,
            now: context.now,
            historyDays: context.historyDays,
            calendar: calendar,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: isPartial,
            monetaryValuesAreAvailable: hasMonetaryCosts,
            costProvenance: hasMonetaryCosts ? .listPriceEstimate : .unknown,
            historyLabel: estimateCloudCost
                ? "\(CostReportingPeriod.rolling(days: context.historyDays).label) (Cloud est.)"
                : nil,
            projects: projects,
            sessions: sessions,
            detailsAreComplete: detailsAreComplete)
    }

    private static func fetchVertexCloudServingReport(
        context: VertexAITokenLoadContext,
        calendar: Calendar) async throws -> VertexAIUsageFetcher.OnlineServingReportOutcome
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
            return .failed
        }

        let pricingResolver = CostUsagePricing.ClaudeResolver(
            now: context.now,
            cacheRoot: context.scannerOptions.cacheRoot)
        let cloudSince = CostReportingPeriod.rolling(days: context.historyDays)
            .bounds(now: context.now, calendar: calendar)
            .lowerBound
        let queryOptions = VertexAIQueryOptions(
            locationFilter: context.vertexAISettings.regionFilter,
            baseModelFilter: context.vertexAISettings.modelFilter,
            includeOnlineServing: true,
            servingWindowDays: context.historyDays,
            estimateServingCost: context.vertexAISettings.estimateCloudCost)

        do {
            return try await VertexAIUsageFetcher.fetchOnlineServingReport(
                accessToken: credentials.accessToken,
                projectId: credentials.projectId,
                config: VertexAIUsageFetcher.OnlineServingReportConfig(
                    since: cloudSince,
                    until: context.now,
                    calendar: calendar,
                    options: queryOptions,
                    estimateCost: context.vertexAISettings.estimateCloudCost),
                pricingResolver: pricingResolver,
                transport: transport)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed
        }
    }
}

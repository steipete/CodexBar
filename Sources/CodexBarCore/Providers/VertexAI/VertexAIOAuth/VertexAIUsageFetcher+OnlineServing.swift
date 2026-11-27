import Foundation

extension VertexAIUsageFetcher {
    enum OnlineServingReportOutcome {
        case report(CostUsageDailyReport, isPartial: Bool)
        case empty
        case failed

        var report: CostUsageDailyReport? {
            if case let .report(report, _) = self {
                return report
            }
            return nil
        }
    }

    struct OnlineServingReportConfig {
        let since: Date
        let until: Date
        let calendar: Calendar
        let options: VertexAIQueryOptions
        let estimateCost: Bool
    }

    static let onlineServingInvocationFilter = """
    metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_count" \
    AND resource.type="aiplatform.googleapis.com/PublisherModel"
    """
    static let onlineServingTokenFilter = """
    metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count" \
    AND resource.type="aiplatform.googleapis.com/PublisherModel"
    """

    private struct OnlineServingModelKey: Hashable {
        let modelUserID: String
        let location: String
        let publisher: String
        let requestType: String
    }

    private struct OnlineServingBucketKey: Hashable {
        let modelKey: OnlineServingModelKey
        let hour: Date?
    }

    private struct OnlineServingBucketAccumulator {
        var invocations: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var hasTokenData: Bool = false
    }

    private struct OnlineServingModelAccumulator {
        var invocations: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var hasIncompleteBucket: Bool = false
    }

    private static func collectOnlineServingModels(
        invocationSeries: [MonitoringTimeSeries],
        tokenSeries: [MonitoringTimeSeries],
        tokenQueryFailed: Bool,
        options: VertexAIQueryOptions) -> [OnlineServingModelKey: OnlineServingModelAccumulator]
    {
        let utcCalendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        var buckets: [OnlineServingBucketKey: OnlineServingBucketAccumulator] = [:]

        for series in invocationSeries {
            guard let key = Self.servingSeriesKey(series, options: options) else { continue }
            let modelKey = OnlineServingModelKey(
                modelUserID: key.modelUserID,
                location: key.location,
                publisher: key.publisher,
                requestType: key.requestType)
            for point in series.points {
                guard let rawValue = Self.pointValue(from: point), rawValue.isFinite, rawValue > 0 else { continue }
                let count = Int(rawValue.rounded())
                guard count > 0 else { continue }
                let hour = Self.pointDate(from: point).map { date in
                    utcCalendar.dateInterval(of: .hour, for: date)?.start ?? date
                }
                let bucketKey = OnlineServingBucketKey(modelKey: modelKey, hour: hour)
                buckets[bucketKey, default: OnlineServingBucketAccumulator()].invocations += count
            }
        }

        for series in tokenSeries {
            guard let key = Self.servingSeriesKey(series, options: options) else { continue }
            let tokenType = (series.metric.labels?["type"] ?? "input").lowercased()
            let modelKey = OnlineServingModelKey(
                modelUserID: key.modelUserID,
                location: key.location,
                publisher: key.publisher,
                requestType: key.requestType)
            for point in series.points {
                guard let rawValue = Self.pointValue(from: point), rawValue.isFinite, rawValue > 0 else { continue }
                let count = Int(rawValue.rounded())
                guard count > 0 else { continue }
                let hour = Self.pointDate(from: point).map { date in
                    utcCalendar.dateInterval(of: .hour, for: date)?.start ?? date
                }
                let bucketKey = OnlineServingBucketKey(modelKey: modelKey, hour: hour)
                if tokenType == "output" {
                    buckets[bucketKey, default: OnlineServingBucketAccumulator()].outputTokens += count
                } else {
                    buckets[bucketKey, default: OnlineServingBucketAccumulator()].inputTokens += count
                }
                buckets[bucketKey, default: OnlineServingBucketAccumulator()].hasTokenData = true
            }
        }

        var byModel: [OnlineServingModelKey: OnlineServingModelAccumulator] = [:]
        for (bucketKey, bucket) in buckets {
            var acc = byModel[bucketKey.modelKey, default: OnlineServingModelAccumulator()]
            acc.invocations += bucket.invocations
            acc.inputTokens += bucket.inputTokens
            acc.outputTokens += bucket.outputTokens
            let bucketTokensComplete = !tokenQueryFailed && (bucket.hasTokenData || bucket.invocations == 0)
            if !bucketTokensComplete {
                acc.hasIncompleteBucket = true
            }
            byModel[bucketKey.modelKey] = acc
        }
        return byModel
    }

    static func makeOnlineServingSummary(
        invocationSeries: [MonitoringTimeSeries],
        tokenSeries: [MonitoringTimeSeries],
        tokenQueryFailed: Bool = false,
        options: VertexAIQueryOptions,
        pricingDate: Date = Date(),
        pricingResolver: CostUsagePricing.ClaudeResolver? = nil) -> VertexAIOnlineServingSummary?
    {
        let byModel = Self.collectOnlineServingModels(
            invocationSeries: invocationSeries,
            tokenSeries: tokenSeries,
            tokenQueryFailed: tokenQueryFailed,
            options: options)

        guard !byModel.isEmpty else { return nil }

        let resolvedPricing: CostUsagePricing.ClaudeResolver? = if options.estimateServingCost {
            pricingResolver ?? CostUsagePricing.ClaudeResolver(now: pricingDate, cacheRoot: nil)
        } else {
            nil
        }
        resolvedPricing?.prepareCatalog()

        let models = byModel.map { key, acc in
            let isDedicated = key.requestType.caseInsensitiveCompare("dedicated") == .orderedSame
            let modelTokensComplete = !tokenQueryFailed && !acc.hasIncompleteBucket
            let totalTokens = acc.inputTokens + acc.outputTokens
            let estimatedCostUSD: Double? = if let resolvedPricing, !isDedicated, modelTokensComplete, totalTokens > 0 {
                Self.estimateServingCostUSD(
                    modelName: Self.normalizedModelName(key.modelUserID),
                    inputTokens: acc.inputTokens,
                    outputTokens: acc.outputTokens,
                    pricingDate: pricingDate,
                    pricingResolver: resolvedPricing)
            } else {
                nil
            }
            return VertexAIOnlineServingModelSummary(
                modelUserID: key.modelUserID,
                location: key.location,
                publisher: key.publisher,
                requestType: key.requestType,
                invocations: acc.invocations,
                inputTokens: acc.inputTokens,
                outputTokens: acc.outputTokens,
                estimatedCostUSD: estimatedCostUSD,
                tokensAreComplete: modelTokensComplete)
        }.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens {
                return lhs.totalTokens > rhs.totalTokens
            }
            if lhs.invocations != rhs.invocations {
                return lhs.invocations > rhs.invocations
            }
            return lhs.modelUserID < rhs.modelUserID
        }

        var totalInvocations = 0
        var inputTokens = 0
        var outputTokens = 0
        var sharedInvocations = 0
        var dedicatedInvocations = 0
        var sharedTokens = 0
        var dedicatedTokens = 0
        var totalEstimatedCost = 0.0
        var hasPricedModel = false
        var hasUnpricedTokens = false
        var tokensAreComplete = !tokenQueryFailed

        for model in models {
            totalInvocations += model.invocations
            inputTokens += model.inputTokens
            outputTokens += model.outputTokens
            if !model.tokensAreComplete {
                tokensAreComplete = false
            }
            if model.requestType.caseInsensitiveCompare("dedicated") == .orderedSame {
                dedicatedInvocations += model.invocations
                dedicatedTokens += model.totalTokens
            } else {
                sharedInvocations += model.invocations
                sharedTokens += model.totalTokens
            }
            if let cost = model.estimatedCostUSD {
                totalEstimatedCost += cost
                hasPricedModel = true
            } else if model.totalTokens > 0 || !model.tokensAreComplete {
                hasUnpricedTokens = true
            }
        }

        return VertexAIOnlineServingSummary(
            totalInvocations: totalInvocations,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            sharedInvocations: sharedInvocations,
            dedicatedInvocations: dedicatedInvocations,
            sharedTokens: sharedTokens,
            dedicatedTokens: dedicatedTokens,
            estimatedCostUSD: hasPricedModel ? totalEstimatedCost : nil,
            hasUnpricedTokens: hasUnpricedTokens,
            tokensAreComplete: tokensAreComplete,
            models: models)
    }

    static func fetchOnlineServingReport(
        accessToken: String,
        projectId: String?,
        config: OnlineServingReportConfig,
        pricingResolver: CostUsagePricing.ClaudeResolver,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> OnlineServingReportOutcome
    {
        guard let projectId, !projectId.isEmpty else {
            return .failed
        }

        let tokenResult = try await Self.fetchServingTimeSeriesResult(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: Self.onlineServingTokenFilter,
                start: config.since,
                end: config.until,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_SUM"),
            transport: transport)
        let invocationResult = try await Self.fetchServingTimeSeriesResult(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: Self.onlineServingInvocationFilter,
                start: config.since,
                end: config.until,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_SUM"),
            transport: transport)

        let tokenQueryFailed = tokenResult == nil
        let invocationQueryFailed = invocationResult == nil
        if tokenQueryFailed && invocationQueryFailed {
            return .failed
        }

        let tokenSeries = tokenResult ?? []
        let invocationSeries = invocationResult ?? []
        guard !tokenSeries.isEmpty || !invocationSeries.isEmpty else {
            return (tokenQueryFailed || invocationQueryFailed) ? .failed : .empty
        }

        guard let built = Self.buildOnlineServingReport(
            tokenSeries: tokenSeries,
            invocationSeries: invocationSeries,
            tokenQueryFailed: tokenQueryFailed,
            config: config,
            pricingResolver: pricingResolver)
        else {
            return (tokenQueryFailed || invocationQueryFailed) ? .failed : .empty
        }
        return .report(
            built.report,
            isPartial: tokenQueryFailed || invocationQueryFailed || built.hasIncompleteTokens)
    }

    static func fetchServingTimeSeriesResult(
        accessToken: String,
        projectId: String,
        query: TimeSeriesQuery,
        transport: any ProviderHTTPTransport) async throws -> [MonitoringTimeSeries]?
    {
        do {
            return try await fetchTimeSeries(
                accessToken: accessToken,
                projectId: projectId,
                query: query,
                transport: transport)
        } catch VertexAIFetchError.unauthorized {
            throw VertexAIFetchError.unauthorized
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw error
            }
            if case let VertexAIFetchError.networkError(inner) = error,
               let urlError = inner as? URLError,
               urlError.code == .cancelled
            {
                throw error
            }
            Self.log.debug("Online serving Monitoring query failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct ServingBucketKey: Hashable {
        let dayKey: String
        let hour: Date
        let modelName: String
        let isDedicated: Bool
    }

    private struct ServingBucketTotals {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var hasTokenData: Bool = false
        var invocations: Int = 0
    }

    private static func buildOnlineServingReport(
        tokenSeries: [MonitoringTimeSeries],
        invocationSeries: [MonitoringTimeSeries],
        tokenQueryFailed: Bool,
        config: OnlineServingReportConfig,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> (report: CostUsageDailyReport, hasIncompleteTokens: Bool)?
    {
        let buckets = Self.collectServingBuckets(
            tokenSeries: tokenSeries,
            invocationSeries: invocationSeries,
            config: config)
        guard !buckets.isEmpty else { return nil }

        if config.estimateCost {
            pricingResolver.prepareCatalog()
        }

        var rawEntries: [CostUsageDailyReport.Entry] = []
        var hourlyBuckets: [Date: CostUsageTemporalTotals] = [:]
        var hasIncompleteTokens = false

        for (key, totals) in buckets {
            let hasKnownTokens = !tokenQueryFailed && (totals.hasTokenData || totals.invocations == 0)
            let knownTotalTokens = totals.inputTokens + totals.outputTokens
            guard (hasKnownTokens && knownTotalTokens > 0) || totals.invocations > 0 else { continue }
            if !hasKnownTokens {
                hasIncompleteTokens = true
            }

            let inputTokens: Int? = hasKnownTokens ? totals.inputTokens : nil
            let outputTokens: Int? = hasKnownTokens ? totals.outputTokens : nil
            let totalTokens: Int? = hasKnownTokens ? knownTotalTokens : nil

            let costUSD: Double? = if config.estimateCost, !key.isDedicated, hasKnownTokens, knownTotalTokens > 0 {
                Self.estimateServingCostUSD(
                    modelName: key.modelName,
                    inputTokens: totals.inputTokens,
                    outputTokens: totals.outputTokens,
                    pricingDate: key.hour,
                    pricingResolver: pricingResolver)
            } else {
                nil
            }

            let requestCount = totals.invocations > 0 ? totals.invocations : nil
            let isUnpriced = config.estimateCost && costUSD == nil && ((totalTokens ?? 0) > 0 || totals.invocations > 0)
            let isPriced = costUSD != nil

            rawEntries.append(CostUsageDailyReport.Entry(
                date: key.dayKey,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens,
                requestCount: requestCount,
                costUSD: costUSD,
                modelsUsed: [key.modelName],
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: key.modelName,
                        costUSD: costUSD,
                        totalTokens: totalTokens,
                        requestCount: requestCount),
                ],
                unpricedRequestCount: isUnpriced ? (requestCount ?? 1) : nil,
                estimatedRequestCount: isPriced ? (requestCount ?? 1) : nil))

            hourlyBuckets[key.hour, default: CostUsageTemporalTotals()].add(
                totalTokens: totalTokens,
                costUSD: costUSD,
                tokensAreComplete: hasKnownTokens,
                costIsComplete: config.estimateCost ? costUSD != nil : false)
        }

        let entries = CostUsageDailyReport.mergedEntries(from: rawEntries, calendar: config.calendar)
        guard !entries.isEmpty else { return nil }

        let hourly = hourlyBuckets.keys.sorted().map { hour in
            hourlyBuckets[hour, default: CostUsageTemporalTotals()].hourlyEntry(hour: hour)
        }
        let summary = CostUsageDailyReport.summary(for: entries)
        return (CostUsageDailyReport(data: entries, summary: summary, hourly: hourly), hasIncompleteTokens)
    }

    private static func collectServingBuckets(
        tokenSeries: [MonitoringTimeSeries],
        invocationSeries: [MonitoringTimeSeries],
        config: OnlineServingReportConfig) -> [ServingBucketKey: ServingBucketTotals]
    {
        var buckets: [ServingBucketKey: ServingBucketTotals] = [:]

        for series in tokenSeries {
            guard let key = Self.servingSeriesKey(series, options: config.options) else { continue }
            let modelName = Self.normalizedModelName(key.modelUserID)
            let tokenType = (series.metric.labels?["type"] ?? "input").lowercased()
            let isDedicated = key.requestType.caseInsensitiveCompare("dedicated") == .orderedSame
            for point in series.points {
                guard let rawValue = Self.pointValue(from: point), rawValue.isFinite, rawValue > 0 else { continue }
                let date = Self.pointDate(from: point) ?? config.until
                let hour = config.calendar.dateInterval(of: .hour, for: date)?.start ?? date
                let dayKey = CostUsageLocalDay.key(from: date, calendar: config.calendar)
                let bucketKey = ServingBucketKey(
                    dayKey: dayKey,
                    hour: hour,
                    modelName: modelName,
                    isDedicated: isDedicated)
                let count = Int(rawValue.rounded())
                if tokenType == "output" {
                    buckets[bucketKey, default: ServingBucketTotals()].outputTokens += count
                } else {
                    buckets[bucketKey, default: ServingBucketTotals()].inputTokens += count
                }
                buckets[bucketKey, default: ServingBucketTotals()].hasTokenData = true
            }
        }

        for series in invocationSeries {
            guard let key = Self.servingSeriesKey(series, options: config.options) else { continue }
            let modelName = Self.normalizedModelName(key.modelUserID)
            let isDedicated = key.requestType.caseInsensitiveCompare("dedicated") == .orderedSame
            for point in series.points {
                guard let rawValue = Self.pointValue(from: point), rawValue.isFinite, rawValue > 0 else { continue }
                let date = Self.pointDate(from: point) ?? config.until
                let hour = config.calendar.dateInterval(of: .hour, for: date)?.start ?? date
                let dayKey = CostUsageLocalDay.key(from: date, calendar: config.calendar)
                let bucketKey = ServingBucketKey(
                    dayKey: dayKey,
                    hour: hour,
                    modelName: modelName,
                    isDedicated: isDedicated)
                buckets[bucketKey, default: ServingBucketTotals()].invocations += Int(rawValue.rounded())
            }
        }
        return buckets
    }

    private static func estimateServingCostUSD(
        modelName: String,
        inputTokens: Int,
        outputTokens: Int,
        pricingDate: Date,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> Double?
    {
        // Monitoring token totals aggregate many requests over hours or days, so per-request
        // long-context thresholds must not trigger on aggregate volume.
        if let vertexCatalogCost = pricingResolver.costUSD(
            model: modelName,
            providerID: "google-vertex",
            inputTokens: inputTokens,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: outputTokens,
            pricingDate: pricingDate,
            applyLongContextThreshold: false)
        {
            return vertexCatalogCost
        }
        return pricingResolver.costUSD(
            model: modelName,
            inputTokens: inputTokens,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: outputTokens,
            pricingDate: pricingDate,
            applyLongContextThreshold: false)
    }

    private static func servingSeriesKey(
        _ series: MonitoringTimeSeries,
        options: VertexAIQueryOptions)
        -> (modelUserID: String, location: String, publisher: String, requestType: String)?
    {
        let resourceLabels = series.resource.labels ?? [:]
        let metricLabels = series.metric.labels ?? [:]
        let location = resourceLabels["location"] ?? "global"
        guard Self.matchesLocationFilter(location, filter: options.locationFilter) else { return nil }

        let modelUserID = resourceLabels["model_user_id"] ?? resourceLabels["model_version_id"] ?? "unknown"
        guard Self.matchesModelFilter(modelUserID, filter: options.baseModelFilter) else { return nil }

        let publisher = resourceLabels["publisher"] ?? "unknown"
        let requestType = metricLabels["request_type"] ?? "shared"
        return (modelUserID: modelUserID, location: location, publisher: publisher, requestType: requestType)
    }
}

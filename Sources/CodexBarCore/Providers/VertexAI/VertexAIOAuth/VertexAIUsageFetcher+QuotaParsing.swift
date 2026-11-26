import Foundation

extension VertexAIUsageFetcher {
    struct MonitoringTimeSeriesResponse: Decodable {
        let timeSeries: [MonitoringTimeSeries]?
        let nextPageToken: String?
    }

    struct MonitoringTimeSeries: Decodable {
        let metric: MonitoringMetric
        let resource: MonitoringResource
        let points: [MonitoringPoint]
    }

    struct MonitoringMetric: Decodable {
        let type: String?
        let labels: [String: String]?
    }

    struct MonitoringResource: Decodable {
        let type: String?
        let labels: [String: String]?
    }

    struct MonitoringInterval: Decodable {
        let startTime: String?
        let endTime: String?
    }

    struct MonitoringPoint: Decodable {
        let interval: MonitoringInterval?
        let value: MonitoringValue
    }

    struct MonitoringValue: Decodable {
        let doubleValue: Double?
        let int64Value: String?
        let boolValue: Bool?
    }

    struct QuotaKey: Hashable {
        let quotaMetric: String
        let limitName: String
        let location: String
    }

    struct ConsumerQuotaMetricsResponse: Decodable {
        let metrics: [ConsumerQuotaMetric]?
        let nextPageToken: String?
    }

    struct ConsumerQuotaMetric: Decodable {
        let metric: String?
        let displayName: String?
        let consumerQuotaLimits: [ConsumerQuotaLimit]?
    }

    struct ConsumerQuotaLimit: Decodable {
        let name: String?
        let metric: String?
        let unit: String?
        let quotaBuckets: [ConsumerQuotaBucket]?
    }

    struct ConsumerQuotaBucket: Decodable {
        let effectiveLimit: String?
        let defaultLimit: String?
        let dimensions: [String: String]?
    }

    struct ConsumerQuotaBucketInfo {
        let limitName: String
        let unit: String?
        let region: String?
        let baseModel: String?
        let effectiveLimit: Double
        let cadence: VertexAIQuotaCadence
    }

    struct ConsumerQuotaMetricInfo {
        let displayName: String?
        let buckets: [ConsumerQuotaBucketInfo]

        func matchingBucket(
            limitName: String,
            location: String,
            baseModelFilter: String?) -> ConsumerQuotaBucketInfo?
        {
            let matching = self.buckets.filter { bucket in
                (limitName.isEmpty || bucket.limitName.isEmpty || bucket.limitName == limitName)
                    && (bucket.region == nil || bucket.region?.caseInsensitiveCompare(location) == .orderedSame)
                    && VertexAIUsageFetcher.matchesModelFilter(bucket.baseModel, filter: baseModelFilter)
            }
            return matching.max { lhs, rhs in
                let lhsScore = (lhs.region != nil ? 2 : 0) + (lhs.baseModel != nil ? 1 : 0)
                let rhsScore = (rhs.region != nil ? 2 : 0) + (rhs.baseModel != nil ? 1 : 0)
                return lhsScore < rhsScore
            }
        }

        func rateCandidates(location: String, baseModelFilter: String?) -> [ConsumerQuotaBucketInfo] {
            let rateBuckets = self.buckets.filter { bucket in
                let normalizedUnit = bucket.unit?.lowercased() ?? ""
                return normalizedUnit.contains("/min") || normalizedUnit.contains("/d")
                    || bucket.limitName.lowercased().contains("perminute")
                    || bucket.limitName.lowercased().contains("perday")
                    || bucket.limitName.lowercased().contains("per_minute")
                    || bucket.limitName.lowercased().contains("per_day")
            }
            let filtered = rateBuckets.filter { bucket in
                (bucket.region == nil || bucket.region?.caseInsensitiveCompare(location) == .orderedSame)
                    && VertexAIUsageFetcher.matchesModelFilter(bucket.baseModel, filter: baseModelFilter)
            }
            var bestByKey: [String: ConsumerQuotaBucketInfo] = [:]
            for bucket in filtered {
                let key = "\(bucket.limitName)|\(bucket.baseModel ?? "")"
                let existing = bestByKey[key]
                let candidateSpecificity = (bucket.region != nil ? 2 : 0) + (bucket.baseModel != nil ? 1 : 0)
                let existingSpecificity = existing.map { ($0.region != nil ? 2 : 0) + ($0.baseModel != nil ? 1 : 0) }
                    ?? -1
                if candidateSpecificity > existingSpecificity {
                    bestByKey[key] = bucket
                }
            }
            return Array(bestByKey.values)
        }
    }

    struct SnapshotInputs {
        let allocationSeries: [MonitoringTimeSeries]
        let rateSeries: [MonitoringTimeSeries]
        let limitSeries: [MonitoringTimeSeries]
        let exceededSeries: [MonitoringTimeSeries]
        let consumerMetrics: [ConsumerQuotaMetric]
        let onlineServingSummary: VertexAIOnlineServingSummary?
        let options: VertexAIQueryOptions
        let now: Date
    }

    private struct BucketBuildContext {
        let limitByKey: [QuotaKey: Double]
        let exceededByKey: [QuotaKey: Double]
        let metadataIndex: [String: ConsumerQuotaMetricInfo]
        let options: VertexAIQueryOptions
        let now: Date
    }

    static func makeQuotaUsageResponse(
        usageSeries: [MonitoringTimeSeries],
        limitSeries: [MonitoringTimeSeries]) throws -> VertexAIUsageResponse
    {
        let usageByKey = Self.aggregate(series: usageSeries)
        let limitByKey = Self.aggregate(series: limitSeries)

        guard !usageByKey.isEmpty, !limitByKey.isEmpty else {
            throw VertexAIFetchError.noData
        }

        var maxPercent: Double?
        var matchedCount = 0
        var matchedUsageKeys: Set<QuotaKey> = []
        var matchedLimitKeys: Set<QuotaKey> = []
        for (usageKey, usage) in usageByKey {
            guard let (limitKey, limit) = Self.matchingLimit(
                for: usageKey,
                in: limitByKey)
            else { continue }
            matchedUsageKeys.insert(usageKey)
            matchedLimitKeys.insert(limitKey)
            matchedCount += 1
            let percent = (usage / limit) * 100.0
            maxPercent = max(maxPercent ?? percent, percent)
        }

        guard let usedPercent = maxPercent, matchedCount > 0 else {
            throw VertexAIFetchError.noData
        }

        let unmatchedUsage = Set(usageByKey.keys).subtracting(matchedUsageKeys).count
        let unmatchedLimit = Set(limitByKey.keys).subtracting(matchedLimitKeys).count
        Self.log.debug("Quota series preview", metadata: [
            "usageKeys": Self.previewKeys(usageByKey),
            "limitKeys": Self.previewKeys(limitByKey),
        ])
        Self.log.info("Parsed quota", metadata: [
            "usedPercent": "\(usedPercent)",
            "usageSeries": "\(usageByKey.count)",
            "limitSeries": "\(limitByKey.count)",
            "matchedSeries": "\(matchedCount)",
            "unmatchedUsage": "\(unmatchedUsage)",
            "unmatchedLimit": "\(unmatchedLimit)",
        ])

        return VertexAIUsageResponse(
            requestsUsedPercent: usedPercent,
            tokensUsedPercent: nil,
            resetsAt: nil,
            resetDescription: nil,
            rawData: nil)
    }

    static func makeSnapshotUsageResponse(_ inputs: SnapshotInputs) throws -> VertexAIUsageResponse {
        let context = BucketBuildContext(
            limitByKey: Self.aggregate(series: inputs.limitSeries),
            exceededByKey: Self.aggregateSum(series: inputs.exceededSeries),
            metadataIndex: Self.buildConsumerQuotaIndex(metrics: inputs.consumerMetrics),
            options: inputs.options,
            now: inputs.now)

        let allocationBuckets = Self.buildAllocationBuckets(
            usageByKey: Self.aggregate(series: inputs.allocationSeries),
            context: context)
        let rateBuckets = Self.buildRateBuckets(
            rateSeries: inputs.rateSeries,
            context: context)

        let hasServing = (inputs.onlineServingSummary?.totalInvocations ?? 0) > 0
            || (inputs.onlineServingSummary?.totalTokens ?? 0) > 0
        guard !allocationBuckets.isEmpty || !rateBuckets.isEmpty || hasServing else {
            throw VertexAIFetchError.noData
        }

        let highestRate = rateBuckets.max { Self.bucketRank($0, $1) }
        let highestAllocation = allocationBuckets.max { Self.bucketRank($0, $1) }
        let overallPercent = [highestRate?.usedPercent, highestAllocation?.usedPercent]
            .compactMap(\.self)
            .max() ?? 0
        let tokenPercent = rateBuckets
            .filter(\.isTokenQuota)
            .max { Self.bucketRank($0, $1) }?.usedPercent
        let totalExceeded = context.exceededByKey.values.reduce(0) { $0 + Int($1.rounded()) }

        return VertexAIUsageResponse(
            requestsUsedPercent: overallPercent,
            tokensUsedPercent: tokenPercent,
            resetsAt: highestRate?.resetsAt,
            resetDescription: nil,
            rawData: nil,
            rateQuotas: rateBuckets.sorted { !Self.bucketRank($0, $1) },
            allocationQuotas: allocationBuckets.sorted { !Self.bucketRank($0, $1) },
            highestRateQuota: highestRate,
            highestAllocationQuota: highestAllocation,
            totalExceededCount: totalExceeded,
            onlineServingSummary: hasServing ? inputs.onlineServingSummary : nil)
    }

    private static func bucketRank(_ lhs: VertexAIQuotaBucketUsage, _ rhs: VertexAIQuotaBucketUsage) -> Bool {
        if lhs.usedPercent != rhs.usedPercent {
            return lhs.usedPercent < rhs.usedPercent
        }
        if lhs.exceededCount != rhs.exceededCount {
            return lhs.exceededCount < rhs.exceededCount
        }
        return lhs.quotaMetric > rhs.quotaMetric
    }

    private static func buildAllocationBuckets(
        usageByKey: [QuotaKey: Double],
        context: BucketBuildContext) -> [VertexAIQuotaBucketUsage]
    {
        var results: [VertexAIQuotaBucketUsage] = []
        for (usageKey, usage) in usageByKey {
            guard Self.matchesLocationFilter(usageKey.location, filter: context.options.locationFilter) else {
                continue
            }
            guard let (limitKey, limit) = Self.matchingLimit(for: usageKey, in: context.limitByKey) else { continue }
            let meta = context.metadataIndex[usageKey.quotaMetric]
            let bucketMeta = meta?.matchingBucket(
                limitName: limitKey.limitName,
                location: usageKey.location,
                baseModelFilter: context.options.baseModelFilter)
            if context.options.baseModelFilter != nil, bucketMeta?.baseModel == nil {
                continue
            }
            let effectiveLimit = bucketMeta?.effectiveLimit ?? limit
            guard effectiveLimit > 0 else { continue }
            let exceeded = Self.matchingExceeded(
                quotaMetric: usageKey.quotaMetric,
                limitName: limitKey.limitName,
                location: usageKey.location,
                in: context.exceededByKey)
            results.append(VertexAIQuotaBucketUsage(
                quotaMetric: usageKey.quotaMetric,
                limitName: limitKey.limitName,
                displayName: meta?.displayName,
                location: usageKey.location,
                baseModel: bucketMeta?.baseModel,
                cadence: .allocation,
                usage: usage,
                limit: effectiveLimit,
                usedPercent: (usage / effectiveLimit) * 100.0,
                exceededCount: exceeded,
                unit: bucketMeta?.unit,
                resetsAt: nil))
        }
        return results
    }

    private struct MetricLocation: Hashable {
        let quotaMetric: String
        let location: String
    }

    private struct RateBucketPoint {
        let date: Date?
        let value: Double
    }

    private static func buildRateBuckets(
        rateSeries: [MonitoringTimeSeries],
        context: BucketBuildContext) -> [VertexAIQuotaBucketUsage]
    {
        let summedByBucket = Self.summedRateBuckets(
            rateSeries: rateSeries,
            locationFilter: context.options.locationFilter)
        let startOfPacificDay = Self.startOfPacificDay(for: context.now)
        let nextPacificMidnight = Self.nextPacificMidnight(after: context.now)
        var results: [VertexAIQuotaBucketUsage] = []

        for (metricLocation, buckets) in summedByBucket {
            let peakPerMinute = buckets.values.map(\.value).max() ?? 0
            let pacificDailySum = buckets.values.reduce(0.0) { partial, point in
                if let date = point.date, date < startOfPacificDay {
                    return partial
                }
                return partial + point.value
            }

            let meta = context.metadataIndex[metricLocation.quotaMetric]
            let consumerCandidates = meta?.rateCandidates(
                location: metricLocation.location,
                baseModelFilter: context.options.baseModelFilter) ?? []

            if !consumerCandidates.isEmpty {
                for candidate in consumerCandidates {
                    let monitoringLimit = Self.matchingMonitoringLimit(
                        quotaMetric: metricLocation.quotaMetric,
                        limitName: candidate.limitName,
                        location: metricLocation.location,
                        in: context.limitByKey)
                    let resolvedLimit = monitoringLimit ?? candidate.effectiveLimit
                    guard resolvedLimit > 0 else { continue }
                    let usage = candidate.cadence == .perDay ? pacificDailySum : peakPerMinute
                    let exceeded = Self.matchingExceeded(
                        quotaMetric: metricLocation.quotaMetric,
                        limitName: candidate.limitName,
                        location: metricLocation.location,
                        in: context.exceededByKey)
                    results.append(VertexAIQuotaBucketUsage(
                        quotaMetric: metricLocation.quotaMetric,
                        limitName: candidate.limitName,
                        displayName: meta?.displayName,
                        location: metricLocation.location,
                        baseModel: candidate.baseModel,
                        cadence: candidate.cadence,
                        usage: usage,
                        limit: resolvedLimit,
                        usedPercent: (usage / resolvedLimit) * 100.0,
                        exceededCount: exceeded,
                        unit: candidate.unit,
                        resetsAt: candidate.cadence == .perDay ? nextPacificMidnight : nil))
                }
                continue
            }

            guard context.options.baseModelFilter == nil else { continue }

            let matchingLimits = context.limitByKey.filter { key, limit in
                limit > 0
                    && key.quotaMetric == metricLocation.quotaMetric
                    && key.location == metricLocation.location
            }
            for (limitKey, limit) in matchingLimits {
                let cadence = Self.inferredCadence(unit: nil, limitName: limitKey.limitName)
                let usage = cadence == .perDay ? pacificDailySum : peakPerMinute
                let exceeded = Self.matchingExceeded(
                    quotaMetric: metricLocation.quotaMetric,
                    limitName: limitKey.limitName,
                    location: metricLocation.location,
                    in: context.exceededByKey)
                results.append(VertexAIQuotaBucketUsage(
                    quotaMetric: metricLocation.quotaMetric,
                    limitName: limitKey.limitName,
                    displayName: meta?.displayName,
                    location: metricLocation.location,
                    baseModel: nil,
                    cadence: cadence,
                    usage: usage,
                    limit: limit,
                    usedPercent: (usage / limit) * 100.0,
                    exceededCount: exceeded,
                    unit: nil,
                    resetsAt: cadence == .perDay ? nextPacificMidnight : nil))
            }
        }
        return results
    }

    private static func summedRateBuckets(
        rateSeries: [MonitoringTimeSeries],
        locationFilter: String?) -> [MetricLocation: [String: RateBucketPoint]]
    {
        var summedByBucket: [MetricLocation: [String: RateBucketPoint]] = [:]
        for series in rateSeries {
            let metricLabels = series.metric.labels ?? [:]
            let resourceLabels = series.resource.labels ?? [:]
            guard let quotaMetric = metricLabels["quota_metric"] ?? resourceLabels["quota_id"],
                  !quotaMetric.isEmpty
            else { continue }
            let location = resourceLabels["location"] ?? "global"
            guard Self.matchesLocationFilter(location, filter: locationFilter) else { continue }

            let key = MetricLocation(quotaMetric: quotaMetric, location: location)
            for (index, point) in series.points.enumerated() {
                guard let value = Self.pointValue(from: point), value.isFinite else { continue }
                let date = Self.pointDate(from: point)
                let bucketKey = if let date {
                    String(Int64((date.timeIntervalSince1970 / 60.0).rounded(.down)))
                } else {
                    "idx-\(index)"
                }
                let existing = summedByBucket[key]?[bucketKey]
                summedByBucket[key, default: [:]][bucketKey] = RateBucketPoint(
                    date: existing?.date ?? date,
                    value: (existing?.value ?? 0) + value)
            }
        }
        return summedByBucket
    }

    private static func matchingMonitoringLimit(
        quotaMetric: String,
        limitName: String,
        location: String,
        in limitByKey: [QuotaKey: Double]) -> Double?
    {
        if !limitName.isEmpty,
           let exact = limitByKey[QuotaKey(quotaMetric: quotaMetric, limitName: limitName, location: location)],
           exact > 0
        {
            return exact
        }
        if limitName.isEmpty {
            let candidates = limitByKey.filter { key, limit in
                limit > 0 && key.quotaMetric == quotaMetric && key.location == location
            }
            if candidates.count == 1 {
                return candidates.first?.value
            }
        }
        return nil
    }

    private static func matchingExceeded(
        quotaMetric: String,
        limitName: String,
        location: String,
        in exceededByKey: [QuotaKey: Double]) -> Int
    {
        if !limitName.isEmpty,
           let exact = exceededByKey[QuotaKey(quotaMetric: quotaMetric, limitName: limitName, location: location)]
        {
            return Int(exact.rounded())
        }
        let matching = exceededByKey.filter { key, _ in
            key.quotaMetric == quotaMetric && key.location == location
                && (limitName.isEmpty || key.limitName.isEmpty || key.limitName == limitName)
        }
        return Int(matching.values.reduce(0, +).rounded())
    }

    private static func matchingLimit(
        for usageKey: QuotaKey,
        in limitByKey: [QuotaKey: Double]) -> (key: QuotaKey, value: Double)?
    {
        if let exactLimit = limitByKey[usageKey], exactLimit > 0 {
            return (usageKey, exactLimit)
        }

        guard usageKey.limitName.isEmpty else { return nil }
        let candidates = limitByKey.filter { limitKey, limit in
            limit > 0
                && limitKey.quotaMetric == usageKey.quotaMetric
                && limitKey.location == usageKey.location
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return candidate
    }

    private static func buildConsumerQuotaIndex(metrics: [ConsumerQuotaMetric]) -> [String: ConsumerQuotaMetricInfo] {
        var index: [String: ConsumerQuotaMetricInfo] = [:]
        for metric in metrics {
            guard let metricName = metric.metric, !metricName.isEmpty else { continue }
            var buckets: [ConsumerQuotaBucketInfo] = []
            for limit in metric.consumerQuotaLimits ?? [] {
                let limitName = Self.extractLimitName(from: limit.name)
                let cadence = Self.inferredCadence(unit: limit.unit, limitName: limitName)
                for bucket in limit.quotaBuckets ?? [] {
                    let rawLimit = bucket.effectiveLimit ?? bucket.defaultLimit
                    guard let rawLimit, let numericLimit = Double(rawLimit),
                          numericLimit.isFinite, numericLimit > 0
                    else { continue }
                    let dimensions = bucket.dimensions ?? [:]
                    buckets.append(ConsumerQuotaBucketInfo(
                        limitName: limitName,
                        unit: limit.unit,
                        region: dimensions["region"] ?? dimensions["location"],
                        baseModel: dimensions["base_model"],
                        effectiveLimit: numericLimit,
                        cadence: cadence))
                }
            }
            index[metricName] = ConsumerQuotaMetricInfo(displayName: metric.displayName, buckets: buckets)
        }
        return index
    }

    private static func extractLimitName(from resourceName: String?) -> String {
        guard let resourceName, !resourceName.isEmpty else { return "" }
        if let range = resourceName.range(of: "/limits/") {
            return String(resourceName[range.upperBound...])
        }
        return resourceName.split(separator: "/").last.map(String.init) ?? ""
    }

    static func matchesLocationFilter(_ location: String, filter: String?) -> Bool {
        guard let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty else {
            return true
        }
        return location.caseInsensitiveCompare(filter) == .orderedSame
    }

    static func matchesModelFilter(_ model: String?, filter: String?) -> Bool {
        guard let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty else {
            return true
        }
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return false
        }
        let normalizedModel = Self.normalizedModelName(model)
        let normalizedFilter = Self.normalizedModelName(filter)
        return model.caseInsensitiveCompare(filter) == .orderedSame
            || normalizedModel.caseInsensitiveCompare(normalizedFilter) == .orderedSame
    }

    static func normalizedModelName(_ rawModel: String) -> String {
        var trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "/models/") {
            trimmed = String(trimmed[range.upperBound...])
        }
        if let atIndex = trimmed.firstIndex(of: "@") {
            trimmed = String(trimmed[..<atIndex])
        }
        return trimmed
    }

    static func inferredCadence(unit: String?, limitName: String) -> VertexAIQuotaCadence {
        let normalizedUnit = unit?.lowercased() ?? ""
        let normalizedLimit = limitName.lowercased()
        if normalizedUnit.contains("/d/") || normalizedUnit.hasSuffix("/d")
            || normalizedLimit.contains("perday") || normalizedLimit.contains("per_day")
        {
            return .perDay
        }
        return .perMinute
    }

    static func startOfPacificDay(for date: Date) -> Date {
        let tz = TimeZone(identifier: "America/Los_Angeles") ?? TimeZone(secondsFromGMT: -8 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.startOfDay(for: date)
    }

    static func nextPacificMidnight(after date: Date) -> Date {
        let tz = TimeZone(identifier: "America/Los_Angeles") ?? TimeZone(secondsFromGMT: -8 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let startOfToday = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(24 * 60 * 60)
    }

    private static func aggregate(series: [MonitoringTimeSeries]) -> [QuotaKey: Double] {
        var buckets: [QuotaKey: Double] = [:]

        for entry in series {
            guard let key = Self.quotaKey(from: entry),
                  let value = entry.points.compactMap(Self.pointValue).max()
            else {
                continue
            }
            buckets[key] = max(buckets[key] ?? 0, value)
        }

        return buckets
    }

    private static func aggregateSum(series: [MonitoringTimeSeries]) -> [QuotaKey: Double] {
        var buckets: [QuotaKey: Double] = [:]

        for entry in series {
            guard let key = Self.quotaKey(from: entry) else { continue }
            let total = entry.points.compactMap(Self.pointValue).reduce(0, +)
            buckets[key] = (buckets[key] ?? 0) + total
        }

        return buckets
    }

    private static func quotaKey(from series: MonitoringTimeSeries) -> QuotaKey? {
        let metricLabels = series.metric.labels ?? [:]
        let resourceLabels = series.resource.labels ?? [:]
        let quotaMetric = metricLabels["quota_metric"]
            ?? resourceLabels["quota_id"]
        guard let quotaMetric, !quotaMetric.isEmpty else { return nil }
        let limitName = metricLabels["limit_name"] ?? ""
        let location = resourceLabels["location"] ?? "global"
        return QuotaKey(quotaMetric: quotaMetric, limitName: limitName, location: location)
    }

    static func pointValue(from point: MonitoringPoint) -> Double? {
        if let doubleValue = point.value.doubleValue {
            return doubleValue
        }
        if let int64Value = point.value.int64Value {
            return Double(int64Value)
        }
        if let boolValue = point.value.boolValue {
            return boolValue ? 1.0 : 0.0
        }
        return nil
    }

    static func pointDate(from point: MonitoringPoint) -> Date? {
        CostUsageDateParser.parse(point.interval?.startTime)
            ?? CostUsageDateParser.parse(point.interval?.endTime)
    }

    private static func previewKeys(_ map: [QuotaKey: Double], maxCount: Int = 3) -> String {
        guard !map.isEmpty else { return "none" }
        let keys = map.keys.prefix(maxCount).map { key in
            "\(key.quotaMetric)|\(key.limitName)|\(key.location)"
        }
        let suffix = map.count > maxCount ? " +\(map.count - maxCount)" : ""
        return keys.joined(separator: ", ") + suffix
    }
}

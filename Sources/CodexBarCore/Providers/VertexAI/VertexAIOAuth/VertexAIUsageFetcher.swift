import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum VertexAIFetchError: LocalizedError, Sendable {
    case unauthorized
    case forbidden
    case noProject
    case networkError(Error)
    case invalidResponse(String)
    case noData

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Vertex AI request unauthorized. Run `gcloud auth application-default login`."
        case .forbidden:
            "Access forbidden. Check your IAM permissions for Cloud Monitoring."
        case .noProject:
            "No Google Cloud project configured. Run `gcloud config set project PROJECT_ID`."
        case let .networkError(error):
            "Vertex AI network error: \(error.localizedDescription)"
        case let .invalidResponse(message):
            "Vertex AI response was invalid: \(message)"
        case .noData:
            "No Vertex AI usage data found for the current project."
        }
    }
}

public struct VertexAIUsageResponse: Sendable {
    public let requestsUsedPercent: Double
    public let tokensUsedPercent: Double?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let rawData: String?

    public init(
        requestsUsedPercent: Double,
        tokensUsedPercent: Double?,
        resetsAt: Date?,
        resetDescription: String?,
        rawData: String?)
    {
        self.requestsUsedPercent = requestsUsedPercent
        self.tokensUsedPercent = tokensUsedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.rawData = rawData
    }
}

public enum VertexAIUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.vertexAIFetcher)

    // Cloud Monitoring API endpoint for time series
    private static let monitoringEndpoint = "https://monitoring.googleapis.com/v3/projects"
    private static let usageWindowSeconds: TimeInterval = 24 * 60 * 60

    public static func fetchUsage(
        accessToken: String,
        projectId: String?) async throws -> VertexAIUsageResponse
    {
        guard let projectId, !projectId.isEmpty else {
            throw VertexAIFetchError.noProject
        }

        return try await Self.fetchQuotaUsage(
            accessToken: accessToken,
            projectId: projectId)
    }

    private static func fetchQuotaUsage(
        accessToken: String,
        projectId: String) async throws -> VertexAIUsageResponse
    {
        let usageFilter = """
        metric.type="serviceruntime.googleapis.com/quota/allocation/usage" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """
        let limitFilter = """
        metric.type="serviceruntime.googleapis.com/quota/limit" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """

        let usageSeries = try await Self.fetchTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            filter: usageFilter)
        let limitSeries = try await Self.fetchTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            filter: limitFilter)

        let usageByKey = Self.aggregate(series: usageSeries)
        let limitByKey = Self.aggregate(series: limitSeries)

        guard !usageByKey.isEmpty, !limitByKey.isEmpty else {
            throw VertexAIFetchError.noData
        }

        var maxPercent: Double?
        var matchedCount = 0
        var matchedKeys: Set<QuotaKey> = []
        for (key, limit) in limitByKey {
            guard limit > 0, let usage = usageByKey[key] else { continue }
            matchedKeys.insert(key)
            matchedCount += 1
            let percent = (usage / limit) * 100.0
            maxPercent = max(maxPercent ?? percent, percent)
        }

        guard let usedPercent = maxPercent, matchedCount > 0 else {
            throw VertexAIFetchError.noData
        }

        let unmatchedUsage = Set(usageByKey.keys).subtracting(matchedKeys).count
        let unmatchedLimit = Set(limitByKey.keys).subtracting(matchedKeys).count
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

    private struct MonitoringTimeSeriesResponse: Decodable {
        let timeSeries: [MonitoringTimeSeries]?
        let nextPageToken: String?
    }

    private struct MonitoringTimeSeries: Decodable {
        let metric: MonitoringMetric
        let resource: MonitoringResource
        let points: [MonitoringPoint]
    }

    private struct MonitoringMetric: Decodable {
        let type: String?
        let labels: [String: String]?
    }

    private struct MonitoringResource: Decodable {
        let type: String?
        let labels: [String: String]?
    }

    private struct MonitoringPoint: Decodable {
        let value: MonitoringValue
    }

    private struct MonitoringValue: Decodable {
        let doubleValue: Double?
        let int64Value: String?
    }

    private struct QuotaKey: Hashable {
        let quotaMetric: String
        let limitName: String
        let location: String
    }

    private static func fetchTimeSeries(
        accessToken: String,
        projectId: String,
        filter: String) async throws -> [MonitoringTimeSeries]
    {
        let now = Date()
        let start = now.addingTimeInterval(-Self.usageWindowSeconds)
        let formatter = ISO8601DateFormatter()
        var pageToken: String?
        var allSeries: [MonitoringTimeSeries] = []

        repeat {
            guard var components = URLComponents(
                string: "\(Self.monitoringEndpoint)/\(projectId)/timeSeries")
            else {
                throw VertexAIFetchError.invalidResponse("Invalid Monitoring URL")
            }

            var queryItems = [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "interval.startTime", value: formatter.string(from: start)),
                URLQueryItem(name: "interval.endTime", value: formatter.string(from: now)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: "3600s"),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: "ALIGN_MAX"),
                URLQueryItem(name: "view", value: "FULL"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw VertexAIFetchError.invalidResponse("Invalid Monitoring URL")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let data: Data
            let response: URLResponse

            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw VertexAIFetchError.networkError(error)
            }

            guard let http = response as? HTTPURLResponse else {
                throw VertexAIFetchError.invalidResponse("No HTTP response")
            }

            switch http.statusCode {
            case 401:
                throw VertexAIFetchError.unauthorized
            case 403:
                throw VertexAIFetchError.forbidden
            case 200:
                break
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                throw VertexAIFetchError.invalidResponse("HTTP \(http.statusCode): \(body)")
            }

            let decoded = try JSONDecoder().decode(MonitoringTimeSeriesResponse.self, from: data)
            if let series = decoded.timeSeries {
                allSeries.append(contentsOf: series)
            }
            pageToken = decoded.nextPageToken?.isEmpty == false ? decoded.nextPageToken : nil
        } while pageToken != nil

        return allSeries
    }

    private static func aggregate(series: [MonitoringTimeSeries]) -> [QuotaKey: Double] {
        var buckets: [QuotaKey: Double] = [:]

        for entry in series {
            guard let key = Self.quotaKey(from: entry),
                  let value = Self.maxPointValue(from: entry.points)
            else {
                continue
            }
            buckets[key] = max(buckets[key] ?? 0, value)
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

    private static func maxPointValue(from points: [MonitoringPoint]) -> Double? {
        points.compactMap(self.pointValue).max()
    }

    private static func pointValue(from point: MonitoringPoint) -> Double? {
        if let doubleValue = point.value.doubleValue { return doubleValue }
        if let int64Value = point.value.int64Value { return Double(int64Value) }
        return nil
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

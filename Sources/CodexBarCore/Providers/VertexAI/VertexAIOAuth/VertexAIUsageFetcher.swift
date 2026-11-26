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

public enum VertexAIUsageFetcher {
    static let log = CodexBarLog.logger(LogCategories.provider(.vertexai, scope: "fetcher"))

    static let monitoringEndpoint = "https://monitoring.googleapis.com/v3/projects"
    private static let serviceUsageEndpoint = "https://serviceusage.googleapis.com/v1beta1/projects"
    private static let usageWindowSeconds: TimeInterval = 24 * 60 * 60

    struct TimeSeriesQuery {
        let filter: String
        let start: Date
        let end: Date
        let alignmentPeriod: String
        let perSeriesAligner: String
    }

    public static func fetchUsage(
        accessToken: String,
        projectId: String?,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> VertexAIUsageResponse
    {
        guard let projectId, !projectId.isEmpty else {
            throw VertexAIFetchError.noProject
        }

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

        let now = Date()
        let start = now.addingTimeInterval(-Self.usageWindowSeconds)
        let usageSeries = try await Self.fetchTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: usageFilter,
                start: start,
                end: now,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_MAX"),
            transport: transport)
        let limitSeries = try await Self.fetchTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: limitFilter,
                start: start,
                end: now,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_MAX"),
            transport: transport)

        return try Self.makeQuotaUsageResponse(
            usageSeries: usageSeries,
            limitSeries: limitSeries)
    }

    public static func fetchUsageSnapshot(
        accessToken: String,
        projectId: String?,
        options: VertexAIQueryOptions = VertexAIQueryOptions(),
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> VertexAIUsageResponse
    {
        guard let projectId, !projectId.isEmpty else {
            throw VertexAIFetchError.noProject
        }

        let quotaStart = now.addingTimeInterval(-Self.usageWindowSeconds)
        let allocationFilter = """
        metric.type="serviceruntime.googleapis.com/quota/allocation/usage" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """
        let rateFilter = """
        metric.type="serviceruntime.googleapis.com/quota/rate/net_usage" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """
        let limitFilter = """
        metric.type="serviceruntime.googleapis.com/quota/limit" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """
        let exceededFilter = """
        metric.type="serviceruntime.googleapis.com/quota/exceeded" \
        AND resource.type="consumer_quota" \
        AND resource.label.service="aiplatform.googleapis.com"
        """

        let allocationSeries = try await Self.fetchTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: allocationFilter,
                start: quotaStart,
                end: now,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_MAX"),
            transport: transport)
        let limitSeries = try await Self.fetchTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: limitFilter,
                start: quotaStart,
                end: now,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_MAX"),
            transport: transport)
        let rateSeries = try await Self.fetchRateTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: rateFilter,
                start: quotaStart,
                end: now,
                alignmentPeriod: "60s",
                perSeriesAligner: "ALIGN_SUM"),
            transport: transport)
        let exceededSeries = try await Self.fetchOptionalTimeSeries(
            accessToken: accessToken,
            projectId: projectId,
            query: TimeSeriesQuery(
                filter: exceededFilter,
                start: quotaStart,
                end: now,
                alignmentPeriod: "3600s",
                perSeriesAligner: "ALIGN_COUNT_TRUE"),
            transport: transport)
        let consumerMetrics = try await Self.fetchOptionalConsumerQuotaMetrics(
            accessToken: accessToken,
            projectId: projectId,
            transport: transport)

        var onlineServingSummary: VertexAIOnlineServingSummary?
        if options.includeOnlineServing {
            let servingStart = now.addingTimeInterval(
                -TimeInterval(options.servingWindowDays) * Self.usageWindowSeconds)
            let invocationSeries = try await Self.fetchOptionalTimeSeries(
                accessToken: accessToken,
                projectId: projectId,
                query: TimeSeriesQuery(
                    filter: Self.onlineServingInvocationFilter,
                    start: servingStart,
                    end: now,
                    alignmentPeriod: "3600s",
                    perSeriesAligner: "ALIGN_SUM"),
                transport: transport)
            let tokenSeries = try await Self.fetchOptionalTimeSeries(
                accessToken: accessToken,
                projectId: projectId,
                query: TimeSeriesQuery(
                    filter: Self.onlineServingTokenFilter,
                    start: servingStart,
                    end: now,
                    alignmentPeriod: "3600s",
                    perSeriesAligner: "ALIGN_SUM"),
                transport: transport)
            onlineServingSummary = Self.makeOnlineServingSummary(
                invocationSeries: invocationSeries,
                tokenSeries: tokenSeries,
                options: options)
        }

        return try Self.makeSnapshotUsageResponse(SnapshotInputs(
            allocationSeries: allocationSeries,
            rateSeries: rateSeries,
            limitSeries: limitSeries,
            exceededSeries: exceededSeries,
            consumerMetrics: consumerMetrics,
            onlineServingSummary: onlineServingSummary,
            options: options,
            now: now))
    }

    static func parseQuotaUsage(usageData: Data, limitData: Data) throws -> VertexAIUsageResponse {
        let decoder = JSONDecoder()
        let usageResponse = try decoder.decode(MonitoringTimeSeriesResponse.self, from: usageData)
        let limitResponse = try decoder.decode(MonitoringTimeSeriesResponse.self, from: limitData)
        return try Self.makeQuotaUsageResponse(
            usageSeries: usageResponse.timeSeries ?? [],
            limitSeries: limitResponse.timeSeries ?? [])
    }

    private static func fetchRateTimeSeries(
        accessToken: String,
        projectId: String,
        query: TimeSeriesQuery,
        transport: any ProviderHTTPTransport) async throws -> [MonitoringTimeSeries]
    {
        do {
            return try await self.fetchTimeSeries(
                accessToken: accessToken,
                projectId: projectId,
                query: query,
                transport: transport)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VertexAIFetchError {
            switch error {
            case .unauthorized, .forbidden, .networkError:
                throw error
            case .invalidResponse, .noData, .noProject:
                Self.log.debug("Optional rate/net_usage query unavailable: \(error.localizedDescription)")
                return []
            }
        } catch {
            Self.log.debug("Optional rate/net_usage query degraded gracefully: \(error.localizedDescription)")
            return []
        }
    }

    static func fetchOptionalTimeSeries(
        accessToken: String,
        projectId: String,
        query: TimeSeriesQuery,
        transport: any ProviderHTTPTransport) async throws -> [MonitoringTimeSeries]
    {
        do {
            return try await self.fetchTimeSeries(
                accessToken: accessToken,
                projectId: projectId,
                query: query,
                transport: transport)
        } catch VertexAIFetchError.unauthorized {
            throw VertexAIFetchError.unauthorized
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let urlError = underlyingURLError(from: error), urlError.code == .cancelled {
                throw error
            }
            Self.log.debug("Optional Monitoring query degraded gracefully: \(error.localizedDescription)")
            return []
        }
    }

    private static func underlyingURLError(from error: Error) -> URLError? {
        if let urlError = error as? URLError { return urlError }
        if case let VertexAIFetchError.networkError(inner) = error {
            return inner as? URLError
        }
        return nil
    }

    private static func fetchOptionalConsumerQuotaMetrics(
        accessToken: String,
        projectId: String,
        transport: any ProviderHTTPTransport) async throws -> [ConsumerQuotaMetric]
    {
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var allMetrics: [ConsumerQuotaMetric] = []

        repeat {
            guard var components = URLComponents(
                string: "\(Self.serviceUsageEndpoint)/\(projectId)/services/aiplatform.googleapis.com/consumerQuotaMetrics")
            else {
                return []
            }
            var queryItems = [URLQueryItem(name: "pageSize", value: "200")]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            guard let url = components.url else { return [] }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let response: ProviderHTTPResponse
            do {
                response = try await transport.response(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                Self.log.debug("Service Usage consumerQuotaMetrics request failed: \(error.localizedDescription)")
                return []
            }

            if response.statusCode == 401 {
                throw VertexAIFetchError.unauthorized
            }
            guard response.statusCode == 200 else {
                Self.log.debug(
                    "Service Usage consumerQuotaMetrics degraded gracefully",
                    metadata: ["statusCode": "\(response.statusCode)"])
                return []
            }

            guard let decoded = try? JSONDecoder().decode(ConsumerQuotaMetricsResponse.self, from: response.data) else {
                return []
            }
            if let metrics = decoded.metrics {
                allMetrics.append(contentsOf: metrics)
            }
            guard let nextToken = decoded.nextPageToken, !nextToken.isEmpty,
                  seenPageTokens.insert(nextToken).inserted,
                  seenPageTokens.count < 100
            else { break }
            pageToken = nextToken
        } while true

        return allMetrics
    }

    static func fetchTimeSeries(
        accessToken: String,
        projectId: String,
        query: TimeSeriesQuery,
        transport: any ProviderHTTPTransport) async throws -> [MonitoringTimeSeries]
    {
        let formatter = ISO8601DateFormatter()
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var allSeries: [MonitoringTimeSeries] = []

        repeat {
            guard var components = URLComponents(
                string: "\(Self.monitoringEndpoint)/\(projectId)/timeSeries")
            else {
                throw VertexAIFetchError.invalidResponse("Invalid Monitoring URL")
            }

            var queryItems = [
                URLQueryItem(name: "filter", value: query.filter),
                URLQueryItem(name: "interval.startTime", value: formatter.string(from: query.start)),
                URLQueryItem(name: "interval.endTime", value: formatter.string(from: query.end)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: query.alignmentPeriod),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: query.perSeriesAligner),
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

            let response: ProviderHTTPResponse

            do {
                response = try await transport.response(for: request)
            } catch {
                throw VertexAIFetchError.networkError(error)
            }

            switch response.statusCode {
            case 401:
                throw VertexAIFetchError.unauthorized
            case 403:
                throw VertexAIFetchError.forbidden
            case 200:
                break
            default:
                let body = String(data: response.data, encoding: .utf8) ?? ""
                throw VertexAIFetchError.invalidResponse("HTTP \(response.statusCode): \(body)")
            }

            let decoded = try JSONDecoder().decode(MonitoringTimeSeriesResponse.self, from: response.data)
            if let series = decoded.timeSeries {
                allSeries.append(contentsOf: series)
            }
            // Retain this distinct page before stopping a repeated cursor.
            guard let nextToken = decoded.nextPageToken, !nextToken.isEmpty,
                  seenPageTokens.insert(nextToken).inserted else { break }
            guard seenPageTokens.count < 100 else {
                throw VertexAIFetchError.invalidResponse("Monitoring page limit exceeded")
            }
            pageToken = nextToken
        } while true

        return allSeries
    }
}

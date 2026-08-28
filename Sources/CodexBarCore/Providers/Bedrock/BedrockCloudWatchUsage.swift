import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BedrockClaudeActivity: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let requestCount: Int
}

enum BedrockCloudWatchUsageFetcher {
    static let lookbackDays = 14

    private static let maxResponseBytes = 4 * 1024 * 1024
    private static let maxPages = 20
    private static let requestTimeoutSeconds: TimeInterval = 15

    private enum Metric: String, CaseIterable {
        case inputTokens
        case outputTokens
        case requests

        var cloudWatchName: String {
            switch self {
            case .inputTokens: "InputTokenCount"
            case .outputTokens: "OutputTokenCount"
            case .requests: "Invocations"
            }
        }
    }

    private struct RequestContext {
        let credentials: BedrockAWSSigner.Credentials
        let region: String
        let now: Date
        let endpoint: URL
        let transport: any ProviderHTTPTransport
    }

    static func fetch(
        credentials: BedrockAWSSigner.Credentials,
        region: String,
        now: Date,
        endpointOverride: String?,
        transport: any ProviderHTTPTransport) async throws -> BedrockClaudeActivity
    {
        let totals = try await self.fetchTotals(
            credentials: credentials,
            region: region,
            now: now,
            endpointOverride: endpointOverride,
            transport: transport)

        return BedrockClaudeActivity(
            inputTokens: totals[.inputTokens] ?? 0,
            outputTokens: totals[.outputTokens] ?? 0,
            requestCount: totals[.requests] ?? 0)
    }

    private static func fetchTotals(
        credentials: BedrockAWSSigner.Credentials,
        region: String,
        now: Date,
        endpointOverride: String?,
        transport: any ProviderHTTPTransport) async throws -> [Metric: Int]
    {
        let context = try RequestContext(
            credentials: credentials,
            region: region,
            now: now,
            endpoint: self.endpoint(region: region, override: endpointOverride),
            transport: transport)
        var totals: [Metric: Double] = [:]
        var nextToken: String?
        var seenTokens: Set<String> = []
        var pageCount = 0

        repeat {
            pageCount += 1
            guard pageCount <= self.maxPages else {
                throw BedrockUsageError.cloudWatchParseFailed("too many response pages")
            }

            let response = try await self.callPage(
                context: context,
                nextToken: nextToken)
            for (metric, value) in response.totals {
                totals[metric, default: 0] += value
            }
            nextToken = response.nextToken
            if let nextToken, !seenTokens.insert(nextToken).inserted {
                throw BedrockUsageError.cloudWatchParseFailed("repeated NextToken")
            }
        } while nextToken != nil

        var converted: [Metric: Int] = [:]
        for metric in Metric.allCases {
            let total = totals[metric] ?? 0
            guard total.isFinite, total >= 0, total <= Double(Int.max) else {
                throw BedrockUsageError.cloudWatchParseFailed("invalid metric total")
            }
            converted[metric] = Int(total.rounded())
        }
        return converted
    }

    private static func callPage(
        context: RequestContext,
        nextToken: String?) async throws
        -> (totals: [Metric: Double], nextToken: String?)
    {
        let start = context.now.addingTimeInterval(-Double(self.lookbackDays) * 24 * 60 * 60)
        let queries: [[String: Any]] = Metric.allCases.map { metric in
            let search = "SEARCH('{AWS/Bedrock,ModelId} "
                + "MetricName=\"\(metric.cloudWatchName)\" claude', 'Sum', 86400)"
            return [
                "Id": metric.rawValue,
                "Expression": "SUM(\(search))",
                "ReturnData": true,
            ]
        }
        var payload: [String: Any] = [
            "StartTime": start.timeIntervalSince1970,
            "EndTime": context.now.timeIntervalSince1970,
            "ScanBy": "TimestampAscending",
            "MetricDataQueries": queries,
        ]
        if let nextToken {
            payload["NextToken"] = nextToken
        }

        var request = URLRequest(url: context.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "GraniteServiceVersion20100801.GetMetricData",
            forHTTPHeaderField: "X-Amz-Target")
        BedrockAWSSigner.sign(
            request: &request,
            credentials: context.credentials,
            region: context.region,
            service: "monitoring")

        let response = try await context.transport.response(for: request)
        guard response.statusCode == 200 else {
            throw BedrockUsageError.cloudWatchAPIError("HTTP \(response.statusCode)")
        }
        guard response.data.count <= self.maxResponseBytes else {
            throw BedrockUsageError.cloudWatchParseFailed("response exceeds 4 MiB")
        }
        return try self.parsePage(response.data)
    }

    private static func endpoint(region: String, override: String?) throws -> URL {
        if override != nil {
            guard let override = BedrockSettingsReader.cleaned(override),
                  let url = ProviderEndpointOverrideValidator()
                      .validatedURLAllowingLoopbackHTTP(override)
            else {
                throw BedrockUsageError.cloudWatchParseFailed("invalid endpoint override")
            }
            return url
        }
        guard region.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#,
            options: .regularExpression) != nil
        else {
            throw BedrockUsageError.cloudWatchParseFailed("invalid region endpoint")
        }
        // Match the CloudWatch partition suffixes published by the AWS SDK endpoint resolver.
        let suffix = switch region {
        case let region where region.hasPrefix("cn-"):
            "amazonaws.com.cn"
        case let region where region.hasPrefix("eusc-"):
            "amazonaws.eu"
        case let region where region.hasPrefix("us-iso-"):
            "c2s.ic.gov"
        case let region where region.hasPrefix("us-isob-"):
            "sc2s.sgov.gov"
        case let region where region.hasPrefix("eu-isoe-"):
            "cloud.adc-e.uk"
        case let region where region.hasPrefix("us-isof-"):
            "csp.hci.ic.gov"
        default:
            "amazonaws.com"
        }
        guard let url = URL(string: "https://monitoring.\(region).\(suffix)") else {
            throw BedrockUsageError.cloudWatchParseFailed("invalid region endpoint")
        }
        return url
    }

    private static func parsePage(_ data: Data) throws
        -> (totals: [Metric: Double], nextToken: String?)
    {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockUsageError.cloudWatchParseFailed("invalid JSON response")
        }

        if let messages = json["Messages"] as? [[String: Any]], !messages.isEmpty {
            throw BedrockUsageError.cloudWatchParseFailed("CloudWatch reported incomplete results")
        }

        let results = json["MetricDataResults"] as? [[String: Any]] ?? []
        var totals: [Metric: Double] = [:]
        for result in results {
            guard let id = result["Id"] as? String, let metric = Metric(rawValue: id) else {
                throw BedrockUsageError.cloudWatchParseFailed("metric result had an unknown ID")
            }
            guard result["StatusCode"] as? String == "Complete" else {
                throw BedrockUsageError.cloudWatchParseFailed("metric result was incomplete")
            }
            guard let values = result["Values"] as? [Any] else { continue }
            for value in values {
                guard let number = value as? NSNumber else {
                    throw BedrockUsageError.cloudWatchParseFailed("metric value was not numeric")
                }
                let double = number.doubleValue
                guard double.isFinite, double >= 0 else {
                    throw BedrockUsageError.cloudWatchParseFailed("metric value was invalid")
                }
                totals[metric, default: 0] += double
            }
        }

        return (totals, BedrockSettingsReader.cleaned(json["NextToken"] as? String))
    }
}

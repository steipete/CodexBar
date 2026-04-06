import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AWS Bedrock usage snapshot combining cost data and optional budget info.
public struct BedrockUsageSnapshot: Codable, Sendable {
    /// Total Bedrock spend for the current month (USD).
    public let monthlySpend: Double
    /// User-defined monthly budget (USD), if configured.
    public let monthlyBudget: Double?
    /// Total input tokens consumed this month (from CloudWatch), if available.
    public let inputTokens: Int?
    /// Total output tokens consumed this month (from CloudWatch), if available.
    public let outputTokens: Int?
    /// AWS region used for the query.
    public let region: String
    public let updatedAt: Date

    public init(
        monthlySpend: Double,
        monthlyBudget: Double?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        region: String,
        updatedAt: Date)
    {
        self.monthlySpend = monthlySpend
        self.monthlyBudget = monthlyBudget
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.region = region
        self.updatedAt = updatedAt
    }

    /// Budget usage percentage (0-100), only available when a budget is set.
    public var budgetUsedPercent: Double? {
        guard let budget = self.monthlyBudget, budget > 0 else { return nil }
        return min(100, max(0, (self.monthlySpend / budget) * 100))
    }

    /// Total tokens consumed (input + output), if both are available.
    public var totalTokens: Int? {
        guard let input = self.inputTokens, let output = self.outputTokens else { return nil }
        return input + output
    }
}

extension BedrockUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primary: RateWindow? = if let usedPercent = self.budgetUsedPercent {
            RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: Self.endOfCurrentMonth(),
                resetDescription: "Monthly budget")
        } else {
            nil
        }

        let cost = ProviderCostSnapshot(
            used: self.monthlySpend,
            limit: self.monthlyBudget ?? 0,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: Self.endOfCurrentMonth(),
            updatedAt: self.updatedAt)

        var loginParts: [String] = []
        loginParts.append(String(format: "Spend: $%.2f", self.monthlySpend))
        if let budget = self.monthlyBudget {
            loginParts.append(String(format: "Budget: $%.2f", budget))
        }
        if let total = self.totalTokens {
            loginParts.append("Tokens: \(Self.formattedTokenCount(total))")
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .bedrock,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginParts.joined(separator: " · "))

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: cost,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func endOfCurrentMonth() -> Date? {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: Date()) else { return nil }
        let components = calendar.dateComponents([.year, .month], from: Date())
        guard let startOfMonth = calendar.date(from: components) else { return nil }
        return calendar.date(byAdding: .day, value: range.count, to: startOfMonth)
    }

    static func formattedTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}

// MARK: - Fetcher

/// Fetches Bedrock usage data from the AWS Cost Explorer API.
struct BedrockUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.bedrockUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// Fetches current-month Bedrock costs via the AWS Cost Explorer API.
    static func fetchUsage(
        credentials: BedrockAWSSigner.Credentials,
        region: String,
        budget: Double?,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> BedrockUsageSnapshot
    {
        let spend = try await Self.fetchMonthlyCost(
            credentials: credentials,
            region: region,
            environment: environment)

        return BedrockUsageSnapshot(
            monthlySpend: spend,
            monthlyBudget: budget,
            inputTokens: nil,
            outputTokens: nil,
            region: region,
            updatedAt: Date())
    }

    // MARK: - Cost Explorer

    /// Fetches a 30-day daily cost breakdown for the cost history chart.
    static func fetchDailyReport(
        credentials: BedrockAWSSigner.Credentials,
        since: Date,
        until: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> CostUsageDailyReport
    {
        let formatter = Self.dateFormatter()
        let startDate = formatter.string(from: since)
        let endDate = formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)

        let data = try await Self.callCostExplorer(
            startDate: startDate,
            endDate: endDate,
            granularity: "DAILY",
            credentials: credentials,
            environment: environment)

        let entries = try Self.parseDailyResponse(data)
        return CostUsageDailyReport(data: entries, summary: nil)
    }

    private static func fetchMonthlyCost(
        credentials: BedrockAWSSigner.Credentials,
        region: String,
        environment: [String: String]) async throws -> Double
    {
        let (startDate, endDate) = Self.currentMonthRange()

        let data = try await Self.callCostExplorer(
            startDate: startDate,
            endDate: endDate,
            granularity: "MONTHLY",
            credentials: credentials,
            environment: environment)

        return try Self.parseTotalCost(data)
    }

    /// Sends a GetCostAndUsage request to the Cost Explorer API.
    private static func callCostExplorer(
        startDate: String,
        endDate: String,
        granularity: String,
        credentials: BedrockAWSSigner.Credentials,
        environment: [String: String]) async throws -> Data
    {
        // Cost Explorer is a global service; always use us-east-1.
        let ceRegion = "us-east-1"
        let baseURL: URL
        if let override = environment[BedrockSettingsReader.apiURLKey],
           let url = URL(string: BedrockSettingsReader.cleaned(override) ?? "")
        {
            baseURL = url
        } else {
            baseURL = URL(string: "https://ce.\(ceRegion).amazonaws.com")!
        }

        // Use GroupBy to get per-service costs, then filter client-side for Bedrock
        // services. AWS names them per-model (e.g. "Claude Opus 4.6 (Bedrock Edition)")
        // so exact-match filters don't work reliably.
        let requestBody: [String: Any] = [
            "TimePeriod": [
                "Start": startDate,
                "End": endDate,
            ],
            "Granularity": granularity,
            "Metrics": ["UnblendedCost"],
            "GroupBy": [
                ["Type": "DIMENSION", "Key": "SERVICE"],
            ],
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "AWSInsightsIndexService.GetCostAndUsage",
            forHTTPHeaderField: "X-Amz-Target")
        request.timeoutInterval = Self.requestTimeoutSeconds

        BedrockAWSSigner.sign(
            request: &request,
            credentials: credentials,
            region: ceRegion,
            service: "ce")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BedrockUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let summary = Self.sanitizedResponseBody(data)
            Self.log.error("AWS Cost Explorer returned \(httpResponse.statusCode): \(summary)")
            throw BedrockUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    // MARK: - Response parsing

    private static func parseTotalCost(_ data: Data) throws -> Double {
        var total = 0.0
        for (_, cost, _) in try Self.parseGroupedResults(data) {
            total += cost
        }
        return total
    }

    private static func parseDailyResponse(_ data: Data) throws -> [CostUsageDailyReport.Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["ResultsByTime"] as? [[String: Any]]
        else {
            throw BedrockUsageError.parseFailed("Missing ResultsByTime in Cost Explorer response")
        }

        var entries: [CostUsageDailyReport.Entry] = []
        for result in results {
            guard let timePeriod = result["TimePeriod"] as? [String: String],
                  let dateStr = timePeriod["Start"]
            else { continue }

            var dayCost = 0.0
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []

            if let groups = result["Groups"] as? [[String: Any]] {
                for group in groups {
                    guard let keys = group["Keys"] as? [String],
                          let serviceName = keys.first,
                          serviceName.localizedCaseInsensitiveContains("Bedrock")
                    else { continue }

                    if let metrics = group["Metrics"] as? [String: Any],
                       let unblended = metrics["UnblendedCost"] as? [String: Any],
                       let amountStr = unblended["Amount"] as? String,
                       let amount = Double(amountStr), amount > 0
                    {
                        dayCost += amount
                        breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                            modelName: serviceName,
                            costUSD: amount))
                    }
                }
            }

            guard dayCost > 0 else { continue }

            entries.append(CostUsageDailyReport.Entry(
                date: dateStr,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: dayCost,
                modelsUsed: breakdowns.map(\.modelName),
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns))
        }

        return entries
    }

    /// Parses grouped Cost Explorer results, returning (serviceName, cost, dateStr) tuples
    /// for Bedrock-related services only.
    private static func parseGroupedResults(_ data: Data) throws
        -> [(service: String, cost: Double, date: String)]
    {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["ResultsByTime"] as? [[String: Any]]
        else {
            throw BedrockUsageError.parseFailed("Missing ResultsByTime in Cost Explorer response")
        }

        var items: [(service: String, cost: Double, date: String)] = []
        for result in results {
            let dateStr = (result["TimePeriod"] as? [String: String])?["Start"] ?? ""
            guard let groups = result["Groups"] as? [[String: Any]] else { continue }
            for group in groups {
                guard let keys = group["Keys"] as? [String],
                      let serviceName = keys.first,
                      serviceName.localizedCaseInsensitiveContains("Bedrock")
                else { continue }

                if let metrics = group["Metrics"] as? [String: Any],
                   let unblended = metrics["UnblendedCost"] as? [String: Any],
                   let amountStr = unblended["Amount"] as? String,
                   let amount = Double(amountStr)
                {
                    items.append((serviceName, amount, dateStr))
                }
            }
        }
        return items
    }

    // MARK: - Helpers

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private static func currentMonthRange() -> (start: String, end: String) {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: components)!

        let formatter = Self.dateFormatter()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        return (formatter.string(from: startOfMonth), formatter.string(from: tomorrow))
    }

    private static func sanitizedResponseBody(_ data: Data) -> String {
        guard !data.isEmpty,
              let body = String(bytes: data, encoding: .utf8)
        else {
            return "empty body"
        }

        let trimmed = body.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count > 240 {
            let index = trimmed.index(trimmed.startIndex, offsetBy: 240)
            return "\(trimmed[..<index])... [truncated]"
        }

        return trimmed
    }
}

/// Errors that can occur during Bedrock usage fetching.
public enum BedrockUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "AWS credentials not configured. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables or configure in Settings."
        case let .networkError(message):
            "AWS Bedrock network error: \(message)"
        case let .apiError(message):
            "AWS Cost Explorer API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse AWS Cost Explorer response: \(message)"
        }
    }
}

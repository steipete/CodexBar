import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BedrockUsageSnapshot: Codable, Sendable {
    public let monthlySpend: Double
    public let monthlyBudget: Double?
    public let inputTokens: Int?
    public let outputTokens: Int?
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

    public var budgetUsedPercent: Double? {
        guard let budget = self.monthlyBudget, budget > 0 else { return nil }
        return min(100, max(0, (self.monthlySpend / budget) * 100))
    }

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
            loginMethod: loginParts.joined(separator: " - "))

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

enum BedrockUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.bedrockUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15

    private struct CostExplorerQuery {
        let startDate: String
        let endDate: String
        let granularity: String
        let nextPageToken: String?
    }

    static func fetchUsage(
        credentials: BedrockAWSSigner.Credentials,
        region: String,
        budget: Double?,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> BedrockUsageSnapshot
    {
        let spend = try await Self.fetchMonthlyCost(
            credentials: credentials,
            environment: environment)

        return BedrockUsageSnapshot(
            monthlySpend: spend,
            monthlyBudget: budget,
            inputTokens: nil,
            outputTokens: nil,
            region: region,
            updatedAt: Date())
    }

    static func fetchDailyReport(
        credentials: BedrockAWSSigner.Credentials,
        since: Date,
        until: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> CostUsageDailyReport
    {
        let formatter = Self.dateFormatter()
        let startDate = formatter.string(from: since)
        let inclusiveEnd = Self.utcCalendar().date(byAdding: .day, value: 1, to: until) ?? until
        let endDate = formatter.string(from: inclusiveEnd)

        let pages = try await Self.callCostExplorerPages(
            startDate: startDate,
            endDate: endDate,
            granularity: "DAILY",
            credentials: credentials,
            environment: environment)

        let entries = try Self.parseDailyResponses(pages)
        return CostUsageDailyReport(data: entries, summary: nil)
    }

    private static func fetchMonthlyCost(
        credentials: BedrockAWSSigner.Credentials,
        environment: [String: String]) async throws -> Double
    {
        let (startDate, endDate) = Self.currentMonthRange()

        let pages = try await Self.callCostExplorerPages(
            startDate: startDate,
            endDate: endDate,
            granularity: "MONTHLY",
            credentials: credentials,
            environment: environment)

        return try Self.parseTotalCost(pages)
    }

    private static func callCostExplorerPages(
        startDate: String,
        endDate: String,
        granularity: String,
        credentials: BedrockAWSSigner.Credentials,
        environment: [String: String]) async throws -> [Data]
    {
        var pages: [Data] = []
        var nextPageToken: String?
        var seenPageTokens: Set<String> = []

        repeat {
            let page = try await Self.callCostExplorerPage(
                query: CostExplorerQuery(
                    startDate: startDate,
                    endDate: endDate,
                    granularity: granularity,
                    nextPageToken: nextPageToken),
                credentials: credentials,
                environment: environment)
            pages.append(page)
            nextPageToken = try Self.nextPageToken(from: page)
            if let nextPageToken, !seenPageTokens.insert(nextPageToken).inserted {
                throw BedrockUsageError.parseFailed("Cost Explorer returned repeated NextPageToken")
            }
        } while nextPageToken != nil

        return pages
    }

    private static func callCostExplorerPage(
        query: CostExplorerQuery,
        credentials: BedrockAWSSigner.Credentials,
        environment: [String: String]) async throws -> Data
    {
        let ceRegion = "us-east-1"
        let baseURL: URL = if let override = environment[BedrockSettingsReader.apiURLKey],
                              let url = URL(string: BedrockSettingsReader.cleaned(override) ?? "")
        {
            url
        } else {
            URL(string: "https://ce.\(ceRegion).amazonaws.com")!
        }

        var requestBody: [String: Any] = [
            "TimePeriod": [
                "Start": query.startDate,
                "End": query.endDate,
            ],
            "Granularity": query.granularity,
            "Metrics": ["UnblendedCost"],
            "GroupBy": [
                ["Type": "DIMENSION", "Key": "SERVICE"],
            ],
        ]
        if let nextPageToken = query.nextPageToken {
            requestBody["NextPageToken"] = nextPageToken
        }

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

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)

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

    private static func nextPageToken(from data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockUsageError.parseFailed("Invalid Cost Explorer response")
        }
        return BedrockSettingsReader.cleaned(json["NextPageToken"] as? String)
    }

    private static func parseTotalCost(_ pages: [Data]) throws -> Double {
        var total = 0.0
        for page in pages {
            total += try Self.parseTotalCost(page)
        }
        return total
    }

    private static func parseTotalCost(_ data: Data) throws -> Double {
        var total = 0.0
        for (_, cost, _) in try Self.parseGroupedResults(data) {
            total += cost
        }
        return total
    }

    private static func parseDailyResponses(_ pages: [Data]) throws -> [CostUsageDailyReport.Entry] {
        let reports = try pages.map { page in
            try CostUsageDailyReport(data: Self.parseDailyResponse(page), summary: nil)
        }
        return CostUsageDailyReport.merged(reports).data
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
                       let amount = Double(amountStr),
                       amount > 0
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

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func currentMonthRange(now: Date = Date()) -> (start: String, end: String) {
        let calendar = Self.utcCalendar()
        let components = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: components)!

        let formatter = Self.dateFormatter()
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        return (formatter.string(from: startOfMonth), formatter.string(from: tomorrow))
    }

    private static func sanitizedResponseBody(_ data: Data) -> String {
        guard !data.isEmpty,
              let body = String(bytes: data, encoding: .utf8)
        else {
            return "empty body"
        }

        let trimmed = body.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count > 240 {
            let index = trimmed.index(trimmed.startIndex, offsetBy: 240)
            return "\(trimmed[..<index])... [truncated]"
        }

        return trimmed
    }
}

public enum BedrockUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "AWS credentials not configured. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY " +
                "or configure Bedrock in Settings."
        case let .networkError(message):
            "AWS Bedrock network error: \(message)"
        case let .apiError(message):
            "AWS Cost Explorer API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse AWS Cost Explorer response: \(message)"
        }
    }
}

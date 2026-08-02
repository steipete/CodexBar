import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum XAIBillingError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case missingTeamID
    case invalidTeamID
    case authenticationRejected
    case teamNotFound
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Missing xAI Management API key. Add one in Settings or set XAI_MANAGEMENT_API_KEY. " +
                "Inference API keys are not accepted by the Management API."
        case .missingTeamID:
            "Missing xAI team ID. Add it in Settings or set XAI_TEAM_ID " +
                "(shown in the xAI Console URL and team settings)."
        case .invalidTeamID:
            "The xAI team ID must be a single identifier without path separators."
        case .authenticationRejected:
            "xAI rejected the Management API key. Create one in the xAI Console under " +
                "Settings > Management Keys; inference API keys are not accepted."
        case .teamNotFound:
            "xAI returned 404 for this team. Check the team ID, and that the Management key " +
                "belongs to the same team."
        case .rateLimited:
            "xAI Management API rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(statusCode):
            "xAI Management API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse xAI billing data: \(message)"
        }
    }
}

public enum XAIBillingFetcher {
    static let baseURL = URL(string: "https://management-api.x.ai")!
    public static let historyDays = 30
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        managementKey rawKey: String,
        teamID rawTeamID: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> XAIUsageSnapshot
    {
        guard let key = XAISettingsReader.cleaned(rawKey) else {
            throw XAIBillingError.notConfigured
        }
        guard let teamID = XAISettingsReader.cleaned(rawTeamID) else {
            throw XAIBillingError.missingTeamID
        }
        guard !teamID.contains("/"), teamID != ".", teamID != ".." else {
            throw XAIBillingError.invalidTeamID
        }

        let balanceUSD = try await self.fetchBalanceUSD(key: key, teamID: teamID, transport: transport)

        // History is best-effort enrichment: the balance is independently useful,
        // so only credential problems (and cancellation) are allowed to escalate.
        var daily: [XAIUsageSnapshot.DailyBucket] = []
        var limitReached = false
        do {
            (daily, limitReached) = try await self.fetchDailyUsage(
                key: key,
                teamID: teamID,
                transport: transport,
                now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch XAIBillingError.authenticationRejected {
            throw XAIBillingError.authenticationRejected
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
        }

        return XAIUsageSnapshot(
            balanceUSD: balanceUSD,
            daily: daily,
            historyDays: self.historyDays,
            limitReached: limitReached,
            updatedAt: now)
    }

    // MARK: - Balance

    private static func fetchBalanceUSD(
        key: String,
        teamID: String,
        transport: any ProviderHTTPTransport) async throws -> Double
    {
        var request = URLRequest(url: self.teamURL(teamID: teamID, suffix: ["prepaid", "balance"]))
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw self.error(statusCode: response.statusCode)
        }

        let envelope: BalanceEnvelope
        do {
            envelope = try JSONDecoder().decode(BalanceEnvelope.self, from: response.data)
        } catch {
            throw XAIBillingError.parseFailed(error.localizedDescription)
        }
        return try self.balanceUSD(fromLedgerCents: envelope.total.val)
    }

    /// The ledger records credit as negative cents (a $10 top-up is "-1000"),
    /// so the remaining balance is the negated cent value in dollars. A body
    /// without a parseable total must fail loudly — never read as $0.00.
    static func balanceUSD(fromLedgerCents raw: String) throws -> Double {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              let cents = Double(value), cents.isFinite
        else {
            throw XAIBillingError.parseFailed("balance total.val is not a cent amount: \(raw)")
        }
        return -cents / 100.0
    }

    // MARK: - Usage history

    private static func fetchDailyUsage(
        key: String,
        teamID: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> ([XAIUsageSnapshot.DailyBucket], Bool)
    {
        var request = URLRequest(url: self.teamURL(teamID: teamID, suffix: ["usage"]))
        request.httpMethod = "POST"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(self.usageRequestBody(now: now))

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw self.error(statusCode: response.statusCode)
        }

        let envelope: UsageEnvelope
        do {
            envelope = try JSONDecoder().decode(UsageEnvelope.self, from: response.data)
        } catch {
            throw XAIBillingError.parseFailed(error.localizedDescription)
        }

        var totalsByDay: [String: Double] = [:]
        for series in envelope.timeSeries {
            for point in series.dataPoints {
                let day = try self.utcDay(fromTimestamp: point.timestamp)
                totalsByDay[day, default: 0] += point.values.first ?? 0
            }
        }
        let daily = totalsByDay
            .map { XAIUsageSnapshot.DailyBucket(day: $0.key, costUSD: $0.value) }
            .sorted { $0.day < $1.day }
        return (daily, envelope.limitReached ?? false)
    }

    private static func usageRequestBody(now: Date) -> UsageRequestEnvelope {
        let calendar = Self.utcCalendar
        let windowStart = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -(self.historyDays - 1), to: now) ?? now)
        return UsageRequestEnvelope(
            analyticsRequest: .init(
                timeRange: .init(
                    startTime: Self.requestTimestampFormatter.string(from: windowStart),
                    endTime: Self.requestTimestampFormatter.string(from: now),
                    timezone: "Etc/GMT"),
                timeUnit: "TIME_UNIT_DAY",
                values: [.init(name: "usd", aggregation: "AGGREGATION_SUM")],
                groupBy: [],
                filters: []))
    }

    private static func utcDay(fromTimestamp timestamp: String) throws -> String {
        guard let date = iso8601Fractional.date(from: timestamp)
            ?? iso8601.date(from: timestamp)
        else {
            throw XAIBillingError.parseFailed("usage timestamp is not ISO 8601: \(timestamp)")
        }
        return Self.dayFormatter.string(from: date)
    }

    // MARK: - Shared

    private static func teamURL(teamID: String, suffix: [String]) -> URL {
        var url = self.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("billing")
            .appendingPathComponent("teams")
            .appendingPathComponent(teamID)
        for component in suffix {
            url = url.appendingPathComponent(component)
        }
        return url
    }

    private static func error(statusCode: Int) -> XAIBillingError {
        switch statusCode {
        case 401, 403:
            .authenticationRejected
        case 404:
            .teamNotFound
        case 429:
            .rateLimited
        default:
            .apiError(statusCode)
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func utcFormatter(dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = dateFormat
        return formatter
    }

    private static var requestTimestampFormatter: DateFormatter {
        self.utcFormatter(dateFormat: "yyyy-MM-dd HH:mm:ss")
    }

    private static var dayFormatter: DateFormatter {
        self.utcFormatter(dateFormat: "yyyy-MM-dd")
    }

    private static var iso8601Fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var iso8601: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}

// MARK: - Wire types

private struct BalanceEnvelope: Decodable {
    struct Amount: Decodable {
        /// Required: a 200 error envelope must not decode into a $0.00 balance.
        let val: String
    }

    let total: Amount
}

private struct UsageRequestEnvelope: Encodable {
    struct AnalyticsRequest: Encodable {
        struct TimeRange: Encodable {
            let startTime: String
            let endTime: String
            let timezone: String
        }

        struct Value: Encodable {
            let name: String
            let aggregation: String
        }

        let timeRange: TimeRange
        let timeUnit: String
        let values: [Value]
        let groupBy: [String]
        let filters: [String]
    }

    let analyticsRequest: AnalyticsRequest
}

private struct UsageEnvelope: Decodable {
    struct Series: Decodable {
        struct DataPoint: Decodable {
            let timestamp: String
            let values: [Double]
        }

        let dataPoints: [DataPoint]
    }

    let timeSeries: [Series]
    let limitReached: Bool?
}

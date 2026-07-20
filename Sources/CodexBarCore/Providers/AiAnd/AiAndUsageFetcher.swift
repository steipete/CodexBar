import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AiAndUsageError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case authenticationRejected
    case insufficientCredits
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Missing ai& API key. Add one in Settings or set AIAND_API_KEY."
        case .authenticationRejected:
            "ai& rejected the API key. Create a new key at console.aiand.com and update Settings."
        case .insufficientCredits:
            "ai& reports the organization is out of credits. Top up at console.aiand.com."
        case .rateLimited:
            "ai& rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(statusCode):
            "ai& logs API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse ai& usage: \(message)"
        }
    }
}

public struct AiAndUsageSnapshot: Sendable, Equatable {
    public struct Spend: Sendable, Equatable {
        public let amount: Decimal
        public let currencyCode: String

        public init(amount: Decimal, currencyCode: String) {
            self.amount = amount
            self.currencyCode = currencyCode
        }
    }

    /// Nil when the window has no priced rows: the org's billing currency is only
    /// observable from log rows, so an empty window has no currency to report in.
    public let last30DaysSpend: Spend?
    /// False when the request-log page cap was hit before reaching the end of the
    /// 30-day window, so the sum only covers the newest requests.
    public let isComplete: Bool
    public let updatedAt: Date

    public init(last30DaysSpend: Spend?, isComplete: Bool, updatedAt: Date) {
        self.last30DaysSpend = last30DaysSpend
        self.isComplete = isComplete
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // ai& is prepaid with no quota windows; spend is the only usable usage
        // signal, so no RateWindows are synthesized. limit 0 means "no cap".
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: self.last30DaysSpend.map { spend in
                ProviderCostSnapshot(
                    used: NSDecimalNumber(decimal: spend.amount).doubleValue,
                    limit: 0,
                    currencyCode: spend.currencyCode,
                    period: self.isComplete ? "Last 30 days" : "Last 30 days (partial)",
                    updatedAt: self.updatedAt)
            },
            updatedAt: self.updatedAt,
            identity: nil,
            dataConfidence: self.isComplete ? .exact : .estimated)
    }
}

public enum AiAndUsageFetcher {
    static let logsBaseURL = URL(string: "https://api.aiand.com/logs")!
    static let pageLimit = 100
    /// ai& log rows are per-request, so 10 pages covers the newest 1,000 requests
    /// of the 30-day window (Poe caps its per-message history at 5 pages).
    public static let maxPages = 10
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        _ rawCredential: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> AiAndUsageSnapshot
    {
        guard let credential = AiAndSettingsReader.cleaned(rawCredential) else {
            throw AiAndUsageError.notConfigured
        }

        var rows: [LogsEnvelope.Row] = []
        var after: String?
        var afterID: String?
        var isComplete = false

        for _ in 0..<self.maxPages {
            let page = try await self.fetchLogsPage(
                credential: credential,
                after: after,
                afterID: afterID,
                transport: transport)
            rows.append(contentsOf: page.data)
            if !(page.hasMore ?? false) {
                isComplete = true
                break
            }
            guard let nextAfter = page.nextAfter, let nextAfterID = page.nextAfterID else {
                // The server reports more rows but did not return both cursors; the
                // docs warn `after` alone is unsafe, so stop and mark the sum partial.
                break
            }
            after = nextAfter
            afterID = nextAfterID
        }

        return self.summarize(rows: rows, isComplete: isComplete, now: now)
    }

    private static func fetchLogsPage(
        credential: String,
        after: String?,
        afterID: String?,
        transport: any ProviderHTTPTransport) async throws -> LogsEnvelope
    {
        var request = URLRequest(url: self.logsURL(after: after, afterID: afterID))
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw self.error(statusCode: response.statusCode)
        }
        do {
            return try JSONDecoder().decode(LogsEnvelope.self, from: response.data)
        } catch {
            throw AiAndUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func logsURL(after: String?, afterID: String?) -> URL {
        var components = URLComponents(url: self.logsBaseURL, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "range", value: "30days"),
            URLQueryItem(name: "limit", value: String(self.pageLimit)),
        ]
        if let after {
            query.append(URLQueryItem(name: "after", value: after))
        }
        if let afterID {
            query.append(URLQueryItem(name: "after_id", value: afterID))
        }
        components.queryItems = query
        // Cursor timestamps carry a "+00" offset; URLComponents leaves "+" bare in
        // queries, which servers decode as a space, so escape it explicitly.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private static func summarize(
        rows: [LogsEnvelope.Row],
        isComplete: Bool,
        now: Date) -> AiAndUsageSnapshot
    {
        // Rows arrive newest-first; the newest priced row decides the display
        // currency, and only rows in that currency are summed.
        var currency: String?
        var total = Decimal(0)
        for row in rows {
            guard let rawCost = row.cost,
                  let cost = Decimal(string: rawCost, locale: Locale(identifier: "en_US_POSIX")),
                  let rowCurrency = row.currency?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !rowCurrency.isEmpty
            else { continue }
            if currency == nil {
                currency = rowCurrency
            }
            guard rowCurrency == currency else { continue }
            total += cost
        }
        return AiAndUsageSnapshot(
            last30DaysSpend: currency.map { code in
                AiAndUsageSnapshot.Spend(amount: total, currencyCode: code.uppercased())
            },
            isComplete: isComplete,
            updatedAt: now)
    }

    private static func error(statusCode: Int) -> AiAndUsageError {
        switch statusCode {
        case 401:
            .authenticationRejected
        case 402:
            .insufficientCredits
        case 429:
            .rateLimited
        default:
            .apiError(statusCode)
        }
    }
}

private struct LogsEnvelope: Decodable {
    struct Row: Decodable {
        let cost: String?
        let currency: String?
    }

    let data: [Row]
    let hasMore: Bool?
    let nextAfter: String?
    let nextAfterID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextAfter = "next_after"
        case nextAfterID = "next_after_id"
    }
}

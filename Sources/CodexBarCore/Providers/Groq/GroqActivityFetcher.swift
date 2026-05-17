import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GroqActivityEntry: Decodable, Sendable {
    public let organizationID: String?
    public let organizationName: String?
    public let model: String
    public let timestamp: TimeInterval
    public let numRequests: Int
    public let nContextTokensTotal: Int
    public let nNonCachedContextTokensTotal: Int
    public let nGeneratedTokensTotal: Int
    public let serviceTier: String?
    public let cost: Double

    private enum CodingKeys: String, CodingKey {
        case organizationID = "organization_id"
        case organizationName = "organization_name"
        case model
        case timestamp
        case numRequests = "num_requests"
        case nContextTokensTotal = "n_context_tokens_total"
        case nNonCachedContextTokensTotal = "n_non_cached_context_tokens_total"
        case nGeneratedTokensTotal = "n_generated_tokens_total"
        case serviceTier = "service_tier"
        case cost
    }
}

public struct GroqActivityResponse: Decodable, Sendable {
    public let object: String?
    public let data: [GroqActivityEntry]
}

public struct GroqUsageSnapshot: Sendable {
    public let organizationName: String?
    public let totalCost: Double
    public let totalContextTokens: Int
    public let totalGeneratedTokens: Int
    public let totalRequests: Int
    public let startDate: Date
    public let endDate: Date
    public let updatedAt: Date

    public init(
        organizationName: String?,
        totalCost: Double,
        totalContextTokens: Int,
        totalGeneratedTokens: Int,
        totalRequests: Int,
        startDate: Date,
        endDate: Date,
        updatedAt: Date)
    {
        self.organizationName = organizationName
        self.totalCost = totalCost
        self.totalContextTokens = totalContextTokens
        self.totalGeneratedTokens = totalGeneratedTokens
        self.totalRequests = totalRequests
        self.startDate = startDate
        self.endDate = endDate
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let spendText = self.totalCost > 0
            ? "$\(String(format: "%.4f", self.totalCost)) this month"
            : "$0.0000 this month"
        let identity = ProviderIdentitySnapshot(
            providerID: .groq,
            accountEmail: nil,
            accountOrganization: self.organizationName,
            loginMethod: "API spend: \(spendText)")
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum GroqUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingOrgID
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Groq session token. Set sessionToken in ~/.codexbar/config.json or GROQ_SESSION_TOKEN."
        case .missingOrgID:
            "Could not determine Groq organization ID. Set GROQ_ORG_ID or ensure your session token contains the org claim."
        case let .networkError(message):
            "Groq network error: \(message)"
        case let .apiError(message):
            "Groq API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Groq response: \(message)"
        }
    }
}

public struct GroqActivityFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.groqUsage)
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchActivity(
        token: String,
        orgID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> GroqUsageSnapshot
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroqUsageError.missingCredentials }
        guard !orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroqUsageError.missingOrgID
        }

        let (startDate, endDate) = Self.currentMonthRange()
        let url = Self.activityURL(
            baseURL: GroqSettingsReader.apiURL(environment: environment),
            orgID: orgID,
            startDate: startDate,
            endDate: endDate)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(orgID, forHTTPHeaderField: "groq-organization")
        request.timeoutInterval = Self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqUsageError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseSnapshot(
                data: data,
                startDate: startDate,
                endDate: endDate,
                updatedAt: Date())
        case 401, 403:
            throw GroqUsageError.missingCredentials
        default:
            Self.log.error("Groq activity API returned \(httpResponse.statusCode)")
            throw GroqUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    static func _parseSnapshotForTesting(
        _ data: Data,
        startDate: Date,
        endDate: Date,
        updatedAt: Date) throws -> GroqUsageSnapshot
    {
        try self.parseSnapshot(data: data, startDate: startDate, endDate: endDate, updatedAt: updatedAt)
    }

    private static func parseSnapshot(
        data: Data,
        startDate: Date,
        endDate: Date,
        updatedAt: Date) throws -> GroqUsageSnapshot
    {
        let decoded: GroqActivityResponse
        do {
            decoded = try JSONDecoder().decode(GroqActivityResponse.self, from: data)
        } catch {
            throw GroqUsageError.parseFailed(error.localizedDescription)
        }

        var totalCost = 0.0
        var totalContext = 0
        var totalGenerated = 0
        var totalRequests = 0
        var orgName: String?

        for entry in decoded.data {
            totalCost += entry.cost
            totalContext += entry.nContextTokensTotal
            totalGenerated += entry.nGeneratedTokensTotal
            totalRequests += entry.numRequests
            if orgName == nil, let name = entry.organizationName, !name.isEmpty {
                orgName = name
            }
        }

        return GroqUsageSnapshot(
            organizationName: orgName,
            totalCost: max(0, totalCost),
            totalContextTokens: totalContext,
            totalGeneratedTokens: totalGenerated,
            totalRequests: totalRequests,
            startDate: startDate,
            endDate: endDate,
            updatedAt: updatedAt)
    }

    private static func activityURL(baseURL: URL, orgID: String, startDate: Date, endDate: Date) -> URL {
        let path = "platform/v1/organizations/\(orgID)/activity"
        var url = baseURL.appendingPathComponent(path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "start_date", value: "\(Int(startDate.timeIntervalSince1970))"),
            URLQueryItem(name: "end_date", value: "\(Int(endDate.timeIntervalSince1970))"),
        ]
        url = components.url ?? url
        return url
    }

    private static func currentMonthRange() -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? now
        var endComponents = DateComponents()
        endComponents.month = 1
        endComponents.second = -1
        let end = calendar.date(byAdding: endComponents, to: start) ?? now
        return (start, end)
    }
}

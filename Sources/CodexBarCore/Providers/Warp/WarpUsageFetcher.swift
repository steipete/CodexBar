import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WarpUsageSnapshot: Sendable {
    public let requestLimit: Int
    public let requestsUsed: Int
    public let nextRefreshTime: Date?
    public let isUnlimited: Bool
    public let updatedAt: Date
    // Combined bonus credits (user-level + workspace-level)
    public let bonusCreditsRemaining: Int
    public let bonusCreditsTotal: Int
    // Earliest expiring bonus batch with remaining credits
    public let bonusNextExpiration: Date?
    public let bonusNextExpirationRemaining: Int

    public init(
        requestLimit: Int,
        requestsUsed: Int,
        nextRefreshTime: Date?,
        isUnlimited: Bool,
        updatedAt: Date,
        bonusCreditsRemaining: Int = 0,
        bonusCreditsTotal: Int = 0,
        bonusNextExpiration: Date? = nil,
        bonusNextExpirationRemaining: Int = 0
    ) {
        self.requestLimit = requestLimit
        self.requestsUsed = requestsUsed
        self.nextRefreshTime = nextRefreshTime
        self.isUnlimited = isUnlimited
        self.updatedAt = updatedAt
        self.bonusCreditsRemaining = bonusCreditsRemaining
        self.bonusCreditsTotal = bonusCreditsTotal
        self.bonusNextExpiration = bonusNextExpiration
        self.bonusNextExpirationRemaining = bonusNextExpirationRemaining
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double
        if self.isUnlimited {
            usedPercent = 0
        } else if self.requestLimit > 0 {
            usedPercent = min(100, max(0, Double(self.requestsUsed) / Double(self.requestLimit) * 100))
        } else {
            usedPercent = 0
        }

        let resetDescription: String?
        if self.isUnlimited {
            resetDescription = "Unlimited"
        } else {
            resetDescription = "\(self.requestsUsed)/\(self.requestLimit) credits"
        }

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.nextRefreshTime,
            resetDescription: resetDescription)

        // Secondary: combined bonus/add-on credits (user + workspace)
        let bonusUsedPercent: Double = {
            guard self.bonusCreditsTotal > 0 else {
                return self.bonusCreditsRemaining > 0 ? 0 : 100
            }
            let used = self.bonusCreditsTotal - self.bonusCreditsRemaining
            return min(100, max(0, Double(used) / Double(self.bonusCreditsTotal) * 100))
        }()

        var bonusDetail: String?
        if self.bonusCreditsRemaining > 0,
           let expiry = self.bonusNextExpiration,
           self.bonusNextExpirationRemaining > 0
        {
            let dateText = expiry.formatted(date: .abbreviated, time: .shortened)
            bonusDetail = "\(self.bonusNextExpirationRemaining) credits expires on \(dateText)"
        }

        let secondary = RateWindow(
            usedPercent: bonusUsedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: bonusDetail)

        let identity = ProviderIdentitySnapshot(
            providerID: .warp,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum WarpUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(Int, String)
    case graphQLError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Warp API key."
        case let .networkError(message):
            "Warp network error: \(message)"
        case let .apiError(code, message):
            "Warp API error (\(code)): \(message)"
        case let .graphQLError(message):
            "Warp GraphQL error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Warp response: \(message)"
        }
    }
}

public struct WarpUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.warpUsage)
    private static let apiURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let clientID = "warp-app"

    private static let graphQLQuery = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            __typename
            ... on UserOutput {
              user {
                requestLimitInfo {
                  isUnlimited
                  nextRefreshTime
                  requestLimit
                  requestsUsedSinceLastRefresh
                }
                bonusGrants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
                workspaces {
                  bonusGrantsInfo {
                    grants {
                      requestCreditsGranted
                      requestCreditsRemaining
                      expiration
                    }
                  }
                }
              }
            }
          }
        }
        """

    public static func fetchUsage(apiKey: String) async throws -> WarpUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WarpUsageError.missingCredentials
        }

        var request = URLRequest(url: self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.clientID, forHTTPHeaderField: "x-warp-client-id")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:] as [String: Any],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": ProcessInfo.processInfo.operatingSystemVersionString,
                ] as [String: Any],
            ] as [String: Any],
        ]

        let body: [String: Any] = [
            "query": self.graphQLQuery,
            "variables": variables,
            "operationName": "GetRequestLimitInfo",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WarpUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            Self.log.error("Warp API returned \(httpResponse.statusCode): \(body)")
            throw WarpUsageError.apiError(httpResponse.statusCode, body)
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            let truncated = jsonString.prefix(500)
            Self.log.debug("Warp API response (\(data.count) bytes): \(truncated)")
        }

        return try Self.parseResponse(data: data)
    }

    static func _parseResponseForTesting(_ data: Data) throws -> WarpUsageSnapshot {
        try self.parseResponse(data: data)
    }

    private static func parseResponse(data: Data) throws -> WarpUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WarpUsageError.parseFailed("Invalid JSON response.")
        }

        // Check GraphQL errors array (loose match on [Any] to catch non-standard shapes)
        if let errors = json["errors"] as? [Any], !errors.isEmpty {
            let message = (errors.first as? [String: Any])?["message"] as? String
                ?? "Unknown GraphQL error"
            throw WarpUsageError.graphQLError(message)
        }

        guard let dataObj = json["data"] as? [String: Any],
              let userObj = dataObj["user"] as? [String: Any]
        else {
            throw WarpUsageError.parseFailed("Missing data.user in response.")
        }

        guard let typename = userObj["__typename"] as? String else {
            throw WarpUsageError.parseFailed("Missing __typename in user response.")
        }
        guard typename == "UserOutput" else {
            throw WarpUsageError.parseFailed("Unexpected __typename: \(typename)")
        }

        guard let innerUserObj = userObj["user"] as? [String: Any],
              let limitInfo = innerUserObj["requestLimitInfo"] as? [String: Any]
        else {
            throw WarpUsageError.parseFailed("Unable to extract requestLimitInfo from response.")
        }

        // isUnlimited: null or missing defaults to false (conservative safe fallback)
        let isUnlimited: Bool
        switch Self.boolValue(limitInfo["isUnlimited"]) {
        case .some(let value):
            isUnlimited = value
        case .none:
            Self.log.warning("isUnlimited is null or unexpected type, defaulting to false")
            isUnlimited = false
        }

        let requestLimit = Self.intValue(limitInfo["requestLimit"])
        let requestsUsed = Self.intValue(limitInfo["requestsUsedSinceLastRefresh"])

        var nextRefreshTime: Date?
        if let nextRefreshTimeString = limitInfo["nextRefreshTime"] as? String {
            nextRefreshTime = Self.parseDate(nextRefreshTimeString)
        }

        // Parse and combine bonus credits from user-level and workspace-level
        let bonus = Self.parseBonusCredits(from: innerUserObj)

        return WarpUsageSnapshot(
            requestLimit: requestLimit,
            requestsUsed: requestsUsed,
            nextRefreshTime: nextRefreshTime,
            isUnlimited: isUnlimited,
            updatedAt: Date(),
            bonusCreditsRemaining: bonus.remaining,
            bonusCreditsTotal: bonus.total,
            bonusNextExpiration: bonus.nextExpiration,
            bonusNextExpirationRemaining: bonus.nextExpirationRemaining)
    }

    private struct BonusGrant: Sendable {
        let granted: Int
        let remaining: Int
        let expiration: Date?
    }

    private struct BonusSummary: Sendable {
        let remaining: Int
        let total: Int
        let nextExpiration: Date?
        let nextExpirationRemaining: Int
    }

    private static func parseBonusCredits(from userObj: [String: Any]) -> BonusSummary {
        var grants: [BonusGrant] = []

        // User-level bonus grants
        if let bonusGrants = userObj["bonusGrants"] as? [[String: Any]] {
            for grant in bonusGrants {
                grants.append(Self.parseBonusGrant(from: grant))
            }
        }

        // Workspace-level bonus grants
        if let workspaces = userObj["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                if let bonusGrantsInfo = workspace["bonusGrantsInfo"] as? [String: Any],
                   let workspaceGrants = bonusGrantsInfo["grants"] as? [[String: Any]]
                {
                    for grant in workspaceGrants {
                        grants.append(Self.parseBonusGrant(from: grant))
                    }
                }
            }
        }

        let totalRemaining = grants.reduce(0) { $0 + $1.remaining }
        let totalGranted = grants.reduce(0) { $0 + $1.granted }

        let expiring = grants.compactMap { grant -> (date: Date, remaining: Int)? in
            guard grant.remaining > 0, let expiration = grant.expiration else { return nil }
            return (expiration, grant.remaining)
        }

        let nextExpiration: Date?
        let nextExpirationRemaining: Int
        if let earliest = expiring.min(by: { $0.date < $1.date }) {
            let earliestKey = Int(earliest.date.timeIntervalSince1970)
            let remaining = expiring.reduce(0) { result, item in
                let key = Int(item.date.timeIntervalSince1970)
                return result + (key == earliestKey ? item.remaining : 0)
            }
            nextExpiration = earliest.date
            nextExpirationRemaining = remaining
        } else {
            nextExpiration = nil
            nextExpirationRemaining = 0
        }

        return BonusSummary(
            remaining: totalRemaining,
            total: totalGranted,
            nextExpiration: nextExpiration,
            nextExpirationRemaining: nextExpirationRemaining)
    }

    private static func parseBonusGrant(from grant: [String: Any]) -> BonusGrant {
        let granted = self.intValue(grant["requestCreditsGranted"])
        let remaining = self.intValue(grant["requestCreditsRemaining"])
        let expiration = (grant["expiration"] as? String).flatMap(Self.parseDate)
        return BonusGrant(granted: granted, remaining: remaining, expiration: expiration)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let num = value as? NSNumber { return num.intValue }
        if let text = value as? String, let int = Int(text) { return int }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if value is NSNull { return nil }
        if let bool = value as? Bool { return bool }
        if let num = value as? NSNumber { return num.boolValue }
        return nil
    }

    private static func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }
}

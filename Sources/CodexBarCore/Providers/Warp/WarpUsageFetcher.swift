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
        bonusNextExpirationRemaining: Int = 0)
    {
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
        let usedPercent: Double = if self.isUnlimited {
            0
        } else if self.requestLimit > 0 {
            min(100, max(0, Double(self.requestsUsed) / Double(self.requestLimit) * 100))
        } else {
            0
        }

        let resetDescription: String? = if self.isUnlimited {
            "Unlimited"
        } else {
            "\(self.requestsUsed)/\(self.requestLimit) credits"
        }

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.isUnlimited ? nil : self.nextRefreshTime,
            resetDescription: resetDescription)

        // Secondary: combined bonus/add-on credits (user + workspace)
        var bonusDetail: String?
        if self.bonusCreditsRemaining > 0,
           let expiry = self.bonusNextExpiration,
           self.bonusNextExpirationRemaining > 0
        {
            let dateText = expiry.formatted(date: .abbreviated, time: .shortened)
            bonusDetail = "\(self.bonusNextExpirationRemaining) credits expires on \(dateText)"
        }

        let hasBonusWindow = self.bonusCreditsTotal > 0
            || self.bonusCreditsRemaining > 0
            || (bonusDetail?.isEmpty == false)

        let secondary: RateWindow?
        if hasBonusWindow {
            let bonusUsedPercent: Double = {
                guard self.bonusCreditsTotal > 0 else {
                    return self.bonusCreditsRemaining > 0 ? 0 : 100
                }
                let used = self.bonusCreditsTotal - self.bonusCreditsRemaining
                return min(100, max(0, Double(used) / Double(self.bonusCreditsTotal) * 100))
            }()
            secondary = RateWindow(
                usedPercent: bonusUsedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: bonusDetail)
        } else {
            secondary = nil
        }

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
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Warp API key."
        case let .networkError(message):
            "Warp network error: \(message)"
        case let .apiError(code, message):
            "Warp API error (\(code)): \(message)"
        case let .parseFailed(message):
            "Failed to parse Warp response: \(message)"
        }
    }
}

public struct WarpUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.warpUsage)
    private static let apiURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let clientID = "warp-app"
    /// Warp's GraphQL endpoint is fronted by an edge limiter that returns HTTP 429 ("Rate exceeded.")
    /// unless the User-Agent matches the official client pattern (e.g. "Warp/1.0").
    private static let userAgent = "Warp/1.0"

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

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        var request = URLRequest(url: self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.clientID, forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersionString, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:] as [String: Any],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": osVersionString,
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
            let summary = Self.apiErrorSummary(statusCode: httpResponse.statusCode, data: data)
            Self.log.error("Warp API returned \(httpResponse.statusCode): \(summary)")
            throw WarpUsageError.apiError(httpResponse.statusCode, summary)
        }

        do {
            let snapshot = try Self.parseResponse(data: data)
            Self.log.debug(
                "Warp usage parsed requestLimit=\(snapshot.requestLimit) requestsUsed=\(snapshot.requestsUsed) "
                    + "bonusRemaining=\(snapshot.bonusCreditsRemaining) bonusTotal=\(snapshot.bonusCreditsTotal) "
                    + "isUnlimited=\(snapshot.isUnlimited)")
            return snapshot
        } catch {
            Self.log.error("Warp response parse failed bytes=\(data.count) error=\(error.localizedDescription)")
            throw error
        }
    }

    static func _parseResponseForTesting(_ data: Data) throws -> WarpUsageSnapshot {
        try self.parseResponse(data: data)
    }

    static func _apiErrorSummaryForTesting(statusCode: Int, data: Data) -> String {
        self.apiErrorSummary(statusCode: statusCode, data: data)
    }

    private static func parseResponse(data: Data) throws -> WarpUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any]
        else {
            throw WarpUsageError.parseFailed("Root JSON is not an object.")
        }

        if let rawErrors = json["errors"] as? [Any], !rawErrors.isEmpty {
            let messages = rawErrors.compactMap(Self.graphQLErrorMessage(from:))
            let summary = messages.isEmpty ? "GraphQL request failed." : messages.prefix(3).joined(separator: " | ")
            throw WarpUsageError.apiError(200, summary)
        }

        guard let dataObj = json["data"] as? [String: Any],
              let userObj = dataObj["user"] as? [String: Any]
        else {
            throw WarpUsageError.parseFailed("Missing data.user in response.")
        }

        let typeName = (userObj["__typename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let innerUserObj = userObj["user"] as? [String: Any],
              let limitInfo = innerUserObj["requestLimitInfo"] as? [String: Any]
        else {
            if let typeName, !typeName.isEmpty, typeName != "UserOutput" {
                throw WarpUsageError.parseFailed("Unexpected user type '\(typeName)'.")
            }
            throw WarpUsageError.parseFailed("Unable to extract requestLimitInfo from response.")
        }

        let isUnlimited = Self.boolValue(limitInfo["isUnlimited"])
        let requestLimit = self.intValue(limitInfo["requestLimit"])
        let requestsUsed = self.intValue(limitInfo["requestsUsedSinceLastRefresh"])

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

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(normalized) {
                return true
            }
            if ["false", "0", "no"].contains(normalized) {
                return false
            }
        }
        return false
    }

    private static func graphQLErrorMessage(from value: Any) -> String? {
        if let message = value as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any],
           let message = dict["message"] as? String
        {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func apiErrorSummary(statusCode: Int, data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any]
        else {
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                return self.compactSummaryText(text)
            }
            return "Unexpected response body (\(data.count) bytes)."
        }

        if let rawErrors = json["errors"] as? [Any], !rawErrors.isEmpty {
            let messages = rawErrors.compactMap(Self.graphQLErrorMessage(from:))
            let joined = messages.prefix(3).joined(separator: " | ")
            if !joined.isEmpty {
                return self.compactSummaryText(joined)
            }
        }

        if let error = json["error"] as? String {
            let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return self.compactSummaryText(trimmed)
            }
        }

        if let message = json["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return self.compactSummaryText(trimmed)
            }
        }

        return "HTTP \(statusCode) (\(data.count) bytes)."
    }

    private static func compactSummaryText(_ text: String, maxLength: Int = 200) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLength {
            return collapsed
        }
        let limitIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return "\(collapsed[..<limitIndex])..."
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

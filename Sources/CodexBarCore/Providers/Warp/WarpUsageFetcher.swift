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

    public init(
        requestLimit: Int,
        requestsUsed: Int,
        nextRefreshTime: Date?,
        isUnlimited: Bool,
        updatedAt: Date
    ) {
        self.requestLimit = requestLimit
        self.requestsUsed = requestsUsed
        self.nextRefreshTime = nextRefreshTime
        self.isUnlimited = isUnlimited
        self.updatedAt = updatedAt
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

        let rateWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.nextRefreshTime,
            resetDescription: resetDescription)

        let identity = ProviderIdentitySnapshot(
            providerID: .warp,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: rateWindow,
            secondary: nil,
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
    private static let clientVersion = "v0.2026.01.07.08.13.stable_01"

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
        request.setValue(self.clientVersion, forHTTPHeaderField: "x-warp-client-version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:] as [String: Any],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": "15.0",
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
            Self.log.debug("Warp API response: \(jsonString)")
        }

        return try Self.parseResponse(data: data)
    }

    private static func parseResponse(data: Data) throws -> WarpUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let userObj = dataObj["user"] as? [String: Any],
              let innerUserObj = userObj["user"] as? [String: Any],
              let limitInfo = innerUserObj["requestLimitInfo"] as? [String: Any]
        else {
            throw WarpUsageError.parseFailed("Unable to extract requestLimitInfo from response.")
        }

        let isUnlimited = limitInfo["isUnlimited"] as? Bool ?? false
        let requestLimit = limitInfo["requestLimit"] as? Int ?? 0
        let requestsUsed = limitInfo["requestsUsedSinceLastRefresh"] as? Int ?? 0

        var nextRefreshTime: Date?
        if let nextRefreshTimeString = limitInfo["nextRefreshTime"] as? String {
            nextRefreshTime = Self.parseDate(nextRefreshTimeString)
        }

        return WarpUsageSnapshot(
            requestLimit: requestLimit,
            requestsUsed: requestsUsed,
            nextRefreshTime: nextRefreshTime,
            isUnlimited: isUnlimited,
            updatedAt: Date())
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

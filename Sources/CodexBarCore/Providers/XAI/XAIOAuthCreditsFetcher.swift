import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct XAIOAuthCreditsSnapshot: Sendable, Equatable {
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let subscriptionTier: String?

    public init(usedPercent: Double?, resetsAt: Date?, subscriptionTier: String? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.subscriptionTier = subscriptionTier
    }
}

public enum XAIOAuthCreditsFetcher {
    public static let defaultEndpoint = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetch(
        accessToken: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> XAIOAuthCreditsSnapshot
    {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: Self.missingTokenMessage)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw ProviderFetchClassifiedError(
                kind: .apiFailure,
                message: "xAI SuperGrok billing returned an invalid response.")
        } catch {
            throw error
        }

        switch response.statusCode {
        case 200:
            return try self.parseSnapshot(response.data)
        case 401, 403:
            throw ProviderFetchClassifiedError(
                kind: .authenticationExpired,
                message: Self.expiredTokenMessage)
        case 429:
            throw ProviderFetchClassifiedError(
                kind: .rateLimited,
                message: "xAI SuperGrok billing rate limit exceeded. Usage will refresh on the next cycle.")
        default:
            let body = String(data: response.data.prefix(400), encoding: .utf8) ?? ""
            throw ProviderFetchClassifiedError(
                kind: .apiFailure,
                message: "xAI SuperGrok billing failed with HTTP \(response.statusCode): \(body)")
        }
    }

    static func parseSnapshot(_ data: Data) throws -> XAIOAuthCreditsSnapshot {
        let response: CreditsResponse
        do {
            response = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            throw ProviderFetchClassifiedError(
                kind: .parseFailure,
                message: "Could not parse xAI SuperGrok billing usage.")
        }
        let config = response.config
        let subscriptionTier = XAIOAuthUsageMapper.displayName(
            from: config?.subscriptionTier ?? response.subscriptionTier)
        let resetsAt =
            config?.currentPeriod?.end.flatMap(Self.parseISO8601)
            ?? config?.billingPeriodEnd.flatMap(Self.parseISO8601)

        if let percent = config?.creditUsagePercent, percent.isFinite {
            return XAIOAuthCreditsSnapshot(
                usedPercent: min(100, max(0, percent)),
                resetsAt: resetsAt,
                subscriptionTier: subscriptionTier)
        }

        if let cap = config?.onDemandCap?.val,
           cap > 0,
           let used = config?.onDemandUsed?.val
        {
            return XAIOAuthCreditsSnapshot(
                usedPercent: min(100, max(0, used / cap * 100)),
                resetsAt: resetsAt,
                subscriptionTier: subscriptionTier)
        }

        if resetsAt != nil {
            let usedPercent: Double? =
                XAIOAuthUsageMapper.omitsIncludedUsagePercent(subscriptionTier) ? nil : 0
            return XAIOAuthCreditsSnapshot(
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                subscriptionTier: subscriptionTier)
        }

        guard subscriptionTier != nil else {
            throw ProviderFetchClassifiedError(
                kind: .parseFailure,
                message: "Could not parse xAI SuperGrok billing usage.")
        }
        return XAIOAuthCreditsSnapshot(
            usedPercent: nil,
            resetsAt: nil,
            subscriptionTier: subscriptionTier)
    }

    public static let missingTokenMessage =
        "Add a SuperGrok OAuth token in xAI settings, or enable reading Grok CLI credentials."
    public static let expiredTokenMessage =
        "xAI rejected the SuperGrok token. Paste a fresh browser token or re-run `grok login` and retry."

    private static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private struct CreditsResponse: Decodable {
        let config: CreditsConfig?
        let subscriptionTier: String?
    }

    private struct CreditsConfig: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: CurrentPeriod?
        let billingPeriodEnd: String?
        let onDemandCap: CreditsAmount?
        let onDemandUsed: CreditsAmount?
        let subscriptionTier: String?
    }

    private struct CurrentPeriod: Decodable {
        let end: String?
    }

    private struct CreditsAmount: Decodable {
        let val: Double?
    }
}

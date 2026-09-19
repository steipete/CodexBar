import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches credits from the Grok CLI's billing backend. The grok.com gRPC-web endpoint now requires
/// a browser-held WKE keypair (#2812), so the CLI proxy is the supported bearer-token path.
public enum GrokCreditsProxyFetcher {
    public static let defaultEndpoint = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetch(
        credentials: GrokCredentials,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        guard !credentials.isExpired else {
            throw GrokWebBillingError.missingCredentials
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw GrokWebBillingError.invalidResponse
        } catch {
            throw error
        }
        guard response.statusCode == 200 else {
            let body = String(data: response.data.prefix(400), encoding: .utf8) ?? ""
            throw GrokWebBillingError.requestFailed(response.statusCode, body)
        }
        return try Self.parseSnapshot(response.data)
    }

    static func parseSnapshot(_ data: Data, now: Date = .now) throws -> GrokWebBillingSnapshot {
        let response: CreditsResponse
        do {
            response = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            throw GrokWebBillingError.parseFailed
        }
        guard let config = response.config else {
            throw GrokWebBillingError.parseFailed
        }

        let subscriptionTier = GrokPlan.displayName(
            from: config.subscriptionTier ?? response.subscriptionTier)
        let currentPeriodEnd = ISO8601DateParser.parse(config.currentPeriod?.end)
        let resetsAt = currentPeriodEnd ?? ISO8601DateParser.parse(config.billingPeriodEnd)
        // Match the start to the selected end; never combine different billing periods.
        let periodStart = currentPeriodEnd == nil ? config.billingPeriodStart : config.currentPeriod?.start
        let windowMinutes = Self.windowMinutes(start: periodStart, end: resetsAt, now: now)

        if let percent = config.creditUsagePercent, percent.isFinite {
            return GrokWebBillingSnapshot(
                usedPercent: min(100, max(0, percent)),
                resetsAt: resetsAt,
                windowMinutes: windowMinutes,
                subscriptionTier: subscriptionTier)
        }

        if let cap = config.onDemandCap?.val,
           cap > 0,
           let used = config.onDemandUsed?.val
        {
            let percent = min(100, max(0, used / cap * 100))
            return GrokWebBillingSnapshot(
                usedPercent: percent,
                resetsAt: resetsAt,
                windowMinutes: windowMinutes,
                subscriptionTier: subscriptionTier)
        }

        if resetsAt != nil {
            return GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: resetsAt,
                windowMinutes: windowMinutes,
                subscriptionTier: subscriptionTier)
        }

        throw GrokWebBillingError.parseFailed
    }

    private static func windowMinutes(start: String?, end: Date?, now: Date) -> Int? {
        guard let start = ISO8601DateParser.parse(start),
              let end, end > start, start <= now,
              let minutes = Int(exactly: (end.timeIntervalSince(start) / 60).rounded(.down)),
              minutes > 0
        else { return nil }
        return minutes
    }

    private struct CreditsResponse: Decodable {
        let config: CreditsConfig?
        let subscriptionTier: String?
    }

    private struct CreditsConfig: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: CurrentPeriod?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
        let onDemandCap: CreditsAmount?
        let onDemandUsed: CreditsAmount?
        let subscriptionTier: String?
    }

    private struct CurrentPeriod: Decodable {
        let start: String?
        let end: String?
    }

    /// The proxy reports amounts as `{ "val": <number> }`; accept fractional values so an unusual
    /// cap/used shape cannot fail decoding of an otherwise valid response.
    private struct CreditsAmount: Decodable {
        let val: Double?
    }
}

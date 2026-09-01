import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads Muse quota from the Meta Model API.
///
/// The Model API publishes no usage or billing endpoint (see the endpoint list in
/// https://dev.meta.ai/docs/api-reference). What it does document is a set of rate-limit response
/// headers returned alongside successful responses, so quota is read from the headers of the
/// cheapest documented read-only call, `GET /v1/models`, rather than from a request that would
/// spend tokens.
public enum MuseUsageFetcher {
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// https://dev.meta.ai/docs/pricing-rate-limits
    enum RateLimitHeader {
        static let limitTokens = "x-ratelimit-limit-tokens"
        static let remainingTokens = "x-ratelimit-remaining-tokens"
        static let limitRequests = "x-ratelimit-limit-requests"
        static let remainingRequests = "x-ratelimit-remaining-requests"
    }

    /// Documented limits are per minute, per team.
    private static let windowMinutes = 1

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL = MuseSettingsReader.defaultBaseURL,
        localAuth: MuseLocalAuth? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MuseUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MuseUsageError.missingCredentials
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: URLResponse
        do {
            (_, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MuseUsageError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MuseUsageError.networkError("Muse returned an unexpected response.")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw MuseUsageError.invalidAPIKey
        default:
            throw MuseUsageError.networkError("Muse usage request failed (HTTP \(http.statusCode)).")
        }

        let windows = self.rateWindows(from: http)
        return MuseUsageSnapshot(
            primary: windows.tokens,
            secondary: windows.requests,
            accountEmail: localAuth?.accountEmail,
            plan: localAuth?.loginMethod ?? "API key",
            updatedAt: Date())
    }

    /// Maps the documented rate-limit headers onto token and request windows.
    ///
    /// A response without the headers yields no windows; the caller still has a verified-credential
    /// identity to show, because the request itself succeeded.
    static func rateWindows(from response: HTTPURLResponse) -> (tokens: RateWindow?, requests: RateWindow?) {
        (
            tokens: self.window(
                limit: self.headerValue(response, RateLimitHeader.limitTokens),
                remaining: self.headerValue(response, RateLimitHeader.remainingTokens)),
            requests: self.window(
                limit: self.headerValue(response, RateLimitHeader.limitRequests),
                remaining: self.headerValue(response, RateLimitHeader.remainingRequests)))
    }

    private static func headerValue(_ response: HTTPURLResponse, _ name: String) -> Double? {
        guard let raw = response.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        return Double(raw)
    }

    private static func window(limit: Double?, remaining: Double?) -> RateWindow? {
        guard let limit, let remaining, limit > 0 else { return nil }
        let used = ((limit - remaining) / limit) * 100
        return RateWindow(
            usedPercent: max(0, min(100, used)),
            windowMinutes: self.windowMinutes,
            resetsAt: nil,
            resetDescription: nil)
    }
}

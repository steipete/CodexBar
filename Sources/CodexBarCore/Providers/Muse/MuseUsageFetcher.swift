import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Validates a Muse API key against the Meta Model API.
///
/// This reports no usage. The Model API publishes no usage or billing endpoint (see the endpoint list
/// in https://dev.meta.ai/docs/api-reference), and its documented `x-ratelimit-*` headers accompany
/// only billed inference responses — `GET /v1/models` and `GET /v1/status` return none — so reading a
/// quota would mean spending tokens on every refresh and consuming the limit being reported. Token
/// history comes from ``MuseLocalUsageReader`` instead.
///
/// `GET /v1/models` is the cheapest documented read-only call, and answers the one question a key can
/// settle for free: whether it works.
public enum MuseUsageFetcher {
    private static let requestTimeoutSeconds: TimeInterval = 15

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
            return MuseUsageSnapshot(
                accountEmail: localAuth?.accountEmail,
                plan: localAuth?.loginMethod ?? "API key",
                updatedAt: Date())
        case 401, 403:
            throw MuseUsageError.invalidAPIKey
        default:
            throw MuseUsageError.networkError("Muse key check failed (HTTP \(http.statusCode)).")
        }
    }
}

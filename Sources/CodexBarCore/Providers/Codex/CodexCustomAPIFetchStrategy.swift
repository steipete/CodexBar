import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetch strategy for the Codex "Custom API" usage source.
///
/// A single strategy serves both pipelines: its `usage` carries the weekly
/// limit as an `extraRateWindows` entry (no `primary`/`secondary` window, so the
/// menu bar stays on the daily-remaining balance), and its `credits` carries
/// the daily remaining balance + daily `codexCreditLimit`. The main usage fetch
/// only applies `result.usage`; the credits pipeline only applies `result.credits`
/// — so one fetch feeds both without touching either pipeline's apply logic or
/// the credits pipeline's account-scoped guard. The `.auto` chain is unchanged;
/// the custom source is opt-in only.
struct CodexCustomAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "codex.custom"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        CodexCustomProviderCredentials.resolve(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let credentials = CodexCustomProviderCredentials.resolve(env: context.env) else {
            throw CodexCustomUsageError.missingCredentials
        }
        let snapshot = try await Self.fetchSnapshot(credentials: credentials)
        return self.makeResult(
            usage: snapshot.usage,
            credits: snapshot.credits,
            sourceLabel: "custom")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    /// Resolves `GET {baseURL}/v1/usage` from the custom provider base URL.
    static func usageURL(baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedBaseURL = path.split(separator: "/").last == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        return versionedBaseURL.appendingPathComponent("usage")
    }

    /// Fetches and maps the custom provider usage response. Exposed for tests.
    static func fetchSnapshot(
        credentials: (baseURL: URL, apiKey: String),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> CodexCustomUsageSnapshot
    {
        var request = URLRequest(url: self.usageURL(baseURL: credentials.baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexCustomUsageError.apiError(
                "HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        // The provider host is the stable account identifier for a custom API source
        // (no OAuth email is available). Carrying it as the identity's accountEmail lets
        // the credits pipeline's account-scoped guard resolve so credits are refreshed.
        let accountEmail = credentials.baseURL.host
        return try CodexCustomUsageMapper.map(
            data: response.data,
            accountEmail: accountEmail,
            updatedAt: updatedAt)
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}

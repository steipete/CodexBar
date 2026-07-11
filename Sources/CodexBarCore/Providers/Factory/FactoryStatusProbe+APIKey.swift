import Foundation

extension FactoryStatusProbe {
    /// Fetch Factory usage using a Factory API key (`FACTORY_API_KEY` / `fk-…`).
    public func fetch(
        apiKey: String,
        logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FactoryStatusProbeError.missingAPIKey
        }
        let log: (String) -> Void = { msg in logger?("[factory] \(msg)") }
        log("Using Factory API key")
        return try await self.fetchWithBearerToken(trimmed, logger: log)
    }

    func fetchWithBearerToken(
        _ bearerToken: String,
        logger: (String) -> Void) async throws -> FactoryStatusSnapshot
    {
        let candidates = [Self.apiBaseURL, self.baseURL]
        var lastError: Error?
        var preferredAuthError: FactoryStatusProbeError?
        for baseURL in candidates {
            if baseURL != Self.apiBaseURL {
                logger("Trying Factory bearer base URL: \(baseURL.host ?? baseURL.absoluteString)")
            }
            do {
                return try await self.fetchWithCookieHeader(
                    "",
                    bearerToken: bearerToken,
                    baseURL: baseURL)
            } catch {
                if preferredAuthError == nil,
                   let authError = Self.preferredBearerAuthError(from: error)
                {
                    preferredAuthError = authError
                }
                lastError = error
            }
        }
        // Prefer 401/403 auth failures over later host noise (e.g. 404) so API-key Auto mode
        // can map to unauthorizedAPIKey and fall back to cookies/WorkOS.
        if let preferredAuthError { throw preferredAuthError }
        if let lastError { throw lastError }
        throw FactoryStatusProbeError.notLoggedIn
    }

    private static func preferredBearerAuthError(from error: Error) -> FactoryStatusProbeError? {
        guard let factoryError = error as? FactoryStatusProbeError else { return nil }
        switch factoryError {
        case .notLoggedIn:
            return factoryError
        case let .networkError(message)
            where message.contains("HTTP 401") || message.contains("HTTP 403"):
            return factoryError
        default:
            return nil
        }
    }
}

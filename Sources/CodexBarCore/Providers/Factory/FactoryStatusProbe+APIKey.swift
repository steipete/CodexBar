import Foundation

#if os(macOS)

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
}

#else

extension FactoryStatusProbe {
    public func fetch(
        apiKey _: String,
        logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot
    {
        _ = logger
        throw FactoryStatusProbeError.notSupported
    }
}

#endif

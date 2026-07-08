import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension MiniMaxUsageFetcher {
    static func fetchAPITokenUsage(
        apiToken: String,
        region: MiniMaxAPIRegion = .global,
        now: Date = Date(),
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
        async throws -> (snapshot: MiniMaxUsageSnapshot, resolvedRegion: MiniMaxAPIRegion)
    {
        let cleaned = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MiniMaxUsageError.invalidCredentials
        }

        // Historically, MiniMax API token fetching used a China endpoint by default in some configurations. If the
        // user has no persisted region and we default to `.global`, retry the China endpoint when the global host
        // rejects the token so upgrades don't regress existing setups.
        if region != .global {
            let snapshot = try await self.fetchUsageOnce(
                apiToken: cleaned,
                region: region,
                now: now,
                transport: transport)
            return (snapshot, region)
        }

        do {
            let snapshot = try await self.fetchUsageOnce(
                apiToken: cleaned,
                region: .global,
                now: now,
                transport: transport)
            return (snapshot, .global)
        } catch let error as MiniMaxUsageError {
            guard case .invalidCredentials = error else { throw error }
            Self.log.debug("MiniMax API token rejected for global host, retrying China mainland host")
            do {
                let snapshot = try await self.fetchUsageOnce(
                    apiToken: cleaned,
                    region: .chinaMainland,
                    now: now,
                    transport: transport)
                return (snapshot, .chinaMainland)
            } catch {
                // Preserve the original invalid-credentials error so the fetch pipeline can fall back to web.
                Self.log.debug("MiniMax China mainland retry failed, preserving global invalidCredentials")
                throw MiniMaxUsageError.invalidCredentials
            }
        }
    }
}

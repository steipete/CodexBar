import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Checks the CLI's regional usage service before a failed refresh can open browser sign-in.
struct KiroConnectivityGate: Sendable {
    private let transport: any ProviderHTTPTransport
    private let resolveEndpoint: @Sendable () throws -> URL
    private static let logger = CodexBarLog.logger(LogCategories.provider(.kiro))

    init(
        transport: any ProviderHTTPTransport = KiroConnectivityGate.liveTransport,
        resolveEndpoint: @escaping @Sendable () throws -> URL = {
            try KiroUsageLimitsAPI.usageEndpoint(databaseURL: KiroUsageLimitsAPI.stateDatabaseURL())
        })
    {
        self.transport = transport
        self.resolveEndpoint = resolveEndpoint
    }

    func ensureReachable() async throws {
        try Task.checkCancellation()
        let endpoint: URL
        do {
            endpoint = try self.resolveEndpoint()
        } catch KiroUsageLimitsError.credentialsUnavailable {
            // Private CLI state is best effort. Do not block a working CLI or guess another region.
            Self.logger.debug("Kiro connectivity preflight skipped: CLI usage endpoint unavailable")
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Any HTTP response proves the host answers. Preserve network errors and cancellation.
        _ = try await self.transport.data(for: request)
    }

    private static let liveTransport: any ProviderHTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()
}

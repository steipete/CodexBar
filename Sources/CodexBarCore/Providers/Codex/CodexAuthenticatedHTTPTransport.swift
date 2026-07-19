import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CodexAuthenticatedHTTPTransport {
    static let shared = Self.makeClient()

    @TaskLocal static var overrideForTesting: (any ProviderHTTPTransport)?

    static var current: any ProviderHTTPTransport {
        if let override = self.overrideForTesting {
            return override
        }
        return self.shared
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func makeClient(configuration: URLSessionConfiguration? = nil) -> ProviderHTTPClient {
        let configuration = configuration ?? self.makeConfiguration()
        let session = ProviderHTTPClient.redirectGuardedSession(configuration: configuration)
        return ProviderHTTPClient(session: session)
    }
}

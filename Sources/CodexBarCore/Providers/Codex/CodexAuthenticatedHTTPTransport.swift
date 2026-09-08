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

    static func perform(request: URLRequest, transport: any ProviderHTTPTransport) async throws -> Data {
        do {
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200...299:
                return response.data
            case 401:
                throw CodexOAuthFetchError.unauthorized
            default:
                let body = String(data: response.data, encoding: .utf8)
                throw CodexOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw CodexOAuthFetchError.networkError(error)
        }
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

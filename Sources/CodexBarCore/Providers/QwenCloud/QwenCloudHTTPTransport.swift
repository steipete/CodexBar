import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Qwen Cloud transport that applies its OneConsole redirect policy per request.
///
/// Redirect behavior stays provider-local: the shared provider client blocks
/// cross-origin redirects, while Qwen may follow credential-free login navigation.
struct QwenCloudHTTPTransport: ProviderHTTPTransport, @unchecked Sendable {
    private static let sharedSession: URLSession = {
        let configuration = ProviderHTTPClient.defaultConfiguration()
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private let routing: OneConsoleCookieRouting

    init(session: URLSession? = nil, routing: OneConsoleCookieRouting) {
        self.session = session ?? Self.sharedSession
        self.routing = routing
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delegate = RedirectDelegate(routing: self.routing)
        return try await self.session.data(for: request, delegate: delegate)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let routing: OneConsoleCookieRouting

        init(routing: OneConsoleCookieRouting) {
            self.routing = routing
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest) async -> URLRequest?
        {
            guard let original = task.originalRequest else { return nil }
            return self.routing.redirectedRequest(
                forRedirectFrom: original,
                response: response,
                to: request)
        }
    }
}

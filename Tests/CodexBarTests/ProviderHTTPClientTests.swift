import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderHTTPClientTests {
    @Test
    func `default client configuration fails blocked connections promptly`() {
        let configuration = ProviderHTTPClient.defaultConfiguration()

        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 90)
        #if !os(Linux)
        #expect(configuration.waitsForConnectivity == false)
        #endif
    }

    @Test
    func `client loads requests through an injected session`() async throws {
        StubURLProtocol.requests = []
        StubURLProtocol.handler = { request in
            StubURLProtocol.requests.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"ok":true}"#.utf8), response)
        }
        defer {
            StubURLProtocol.handler = nil
            StubURLProtocol.requests = []
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = ProviderHTTPClient(session: URLSession(configuration: configuration))
        let request = try URLRequest(url: #require(URL(string: "https://example.com/status")))

        let (data, response) = try await client.data(for: request)

        let body = try #require(String(data: data, encoding: .utf8))
        #expect(body == #"{"ok":true}"#)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(StubURLProtocol.requests.first?.url?.host == "example.com")
    }

    @Test
    func `response helper unwraps HTTP responses`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-Test": "ok"])!
            return (Data("done".utf8), response)
        }
        let request = try URLRequest(url: #require(URL(string: "https://example.com/ok")))

        let response = try await transport.response(for: request)

        #expect(response.statusCode == 204)
        #expect(response.response.value(forHTTPHeaderField: "X-Test") == "ok")
        #expect(String(data: response.data, encoding: .utf8) == "done")
    }

    @Test
    func `response helper rejects non HTTP responses`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let response = URLResponse(
                url: request.url ?? URL(string: "https://example.com/not-http")!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil)
            return (Data(), response)
        }
        let request = try URLRequest(url: #require(URL(string: "https://example.com/not-http")))

        await #expect(throws: URLError.self) {
            _ = try await transport.response(for: request)
        }
    }

    @Test
    func `response helper retries transient HTTP status once`() async throws {
        let script = ScriptedHTTPTransport(statusCodes: [503, 200])
        let request = try URLRequest(url: #require(URL(string: "https://example.com/retry")))

        let response = try await script.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 200)
        #expect(await script.requestCount() == 2)
    }

    @Test
    func `response helper retries transient URL error once`() async throws {
        let script = ScriptedHTTPTransport(results: [
            .failure(URLError(.timedOut)),
            .success(200),
        ])
        let request = try URLRequest(url: #require(URL(string: "https://example.com/retry-error")))

        let response = try await script.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 200)
        #expect(await script.requestCount() == 2)
    }

    @Test
    func `response helper does not retry non idempotent methods`() async throws {
        let script = ScriptedHTTPTransport(statusCodes: [503, 200])
        var request = try URLRequest(url: #require(URL(string: "https://example.com/post")))
        request.httpMethod = "POST"

        let response = try await script.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 503)
        #expect(await script.requestCount() == 1)
    }

    @Test
    func `response helper does not retry auth failures`() async throws {
        let script = ScriptedHTTPTransport(statusCodes: [403, 200])
        let request = try URLRequest(url: #require(URL(string: "https://example.com/forbidden")))

        let response = try await script.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 403)
        #expect(await script.requestCount() == 1)
    }

    @Test
    func `redirect guard blocks cross origin redirects`() throws {
        var redirectRequest = try URLRequest(url: #require(URL(string: "https://attacker.example/capture")))
        redirectRequest.setValue("[REDACTED]", forHTTPHeaderField: "Cookie")
        redirectRequest.setValue("[REDACTED]", forHTTPHeaderField: "x-api-key")

        let guarded = ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
            originalURL: URL(string: "https://provider.example/usage"),
            redirectRequest: redirectRequest)

        #expect(guarded == nil)
    }

    @Test
    func `redirect guard blocks non HTTPS redirects`() throws {
        var redirectRequest = try URLRequest(url: #require(URL(string: "http://provider.example/capture")))
        redirectRequest.setValue("[REDACTED]", forHTTPHeaderField: "Cookie")

        let guarded = ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
            originalURL: URL(string: "https://provider.example/usage"),
            redirectRequest: redirectRequest)

        #expect(guarded == nil)
    }

    @Test
    func `redirect guard blocks redirects without an original URL`() throws {
        let redirectRequest = try URLRequest(url: #require(URL(string: "https://provider.example/usage/next")))

        let guarded = ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
            originalURL: nil,
            redirectRequest: redirectRequest)

        #expect(guarded == nil)
    }

    @Test
    func `redirect guard blocks port changes`() throws {
        let redirectRequest = try URLRequest(url: #require(URL(string: "https://provider.example:8443/usage")))

        let guarded = ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
            originalURL: URL(string: "https://provider.example/usage"),
            redirectRequest: redirectRequest)

        #expect(guarded == nil)
    }

    @Test
    func `redirect guard preserves same origin HTTPS requests`() throws {
        var redirectRequest = try URLRequest(url: #require(URL(string: "https://provider.example/usage/next")))
        redirectRequest.setValue("[REDACTED]", forHTTPHeaderField: "Cookie")
        redirectRequest.setValue("[REDACTED]", forHTTPHeaderField: "Authorization")
        redirectRequest.setValue("[REDACTED]", forHTTPHeaderField: "x-api-key")
        redirectRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let guarded = try #require(ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
            originalURL: URL(string: "https://provider.example/usage"),
            redirectRequest: redirectRequest))

        #expect(guarded.value(forHTTPHeaderField: "Cookie") == "[REDACTED]")
        #expect(guarded.value(forHTTPHeaderField: "Authorization") == "[REDACTED]")
        #expect(guarded.value(forHTTPHeaderField: "x-api-key") == "[REDACTED]")
        #expect(guarded.value(forHTTPHeaderField: "Accept") == "application/json")
    }
}

extension ProviderHTTPRetryPolicy {
    fileprivate static let testOneRetry = ProviderHTTPRetryPolicy(
        maxRetries: 1,
        baseDelaySeconds: 0,
        maxDelaySeconds: 0)
}

private actor ScriptedHTTPTransport: ProviderHTTPTransport {
    enum Result {
        case success(Int)
        case failure(URLError)
    }

    private var results: [Result]
    private var requests: [URLRequest] = []

    init(statusCodes: [Int]) {
        self.results = statusCodes.map(Result.success)
    }

    init(results: [Result]) {
        self.results = results
    }

    func requestCount() -> Int {
        self.requests.count
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests.append(request)
        let next = self.results.isEmpty ? .success(200) : self.results.removeFirst()
        switch next {
        case let .success(statusCode):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(#"{"ok":true}"#.utf8), response)
        case let .failure(error):
            throw error
        }
    }
}

final class StubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (Data, URLResponse))?>(nil)
    static var handler: ((URLRequest) throws -> (Data, URLResponse))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    nonisolated(unsafe) static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }

        do {
            let (data, response) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

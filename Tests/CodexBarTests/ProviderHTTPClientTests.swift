import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderHTTPClientTests {
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
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, URLResponse))?
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

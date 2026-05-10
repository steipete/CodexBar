import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CopilotUsageFetcherTests {
    @Test
    func `fetchGitHubIdentity uses shared client`() async throws {
        let registered = URLProtocol.registerClass(CopilotHTTPStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CopilotHTTPStubURLProtocol.self)
            }
            CopilotHTTPStubURLProtocol.handler = nil
            CopilotHTTPStubURLProtocol.requests = []
        }

        CopilotHTTPStubURLProtocol.requests = []
        CopilotHTTPStubURLProtocol.handler = { request in
            CopilotHTTPStubURLProtocol.requests.append(request)
            guard request.value(forHTTPHeaderField: "Authorization") == "token abc123" else {
                throw URLError(.userAuthenticationRequired)
            }
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"login":"testuser","id":123}"#.utf8), response)
        }

        let identity = try await CopilotUsageFetcher.fetchGitHubIdentity(token: "abc123")

        #expect(identity.login == "testuser")
        #expect(identity.id == 123)
        #expect(CopilotHTTPStubURLProtocol.requests.count == 1)
        #expect(CopilotHTTPStubURLProtocol.requests.first?.url?.host == "api.github.com")
    }
}

final class CopilotHTTPStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, URLResponse))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
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

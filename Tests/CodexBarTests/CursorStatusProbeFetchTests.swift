import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct CursorStatusProbeFetchTests {
    @Test
    func `fetches snapshot using cookie header override`() async throws {
        let registered = URLProtocol.registerClass(CursorStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CursorStubURLProtocol.self)
            }
            CursorStubURLProtocol.handler = nil
        }

        CursorStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/usage-summary":
                let body = """
                {
                  "billingCycleEnd": "2026-05-01T00:00:00.000Z",
                  "membershipType": "pro",
                  "individualUsage": {
                    "plan": {
                      "enabled": true,
                      "used": 1000,
                      "limit": 2000,
                      "remaining": 1000,
                      "totalPercentUsed": 50.0
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            case "/api/auth/me":
                let body = """
                {
                  "email": "user@example.com",
                  "email_verified": true,
                  "name": "Test User",
                  "sub": "user_123"
                }
                """
                return Self.makeResponse(url: url, body: body)
            case "/api/usage":
                let body = """
                {
                  "gpt-4": {
                    "numRequestsTotal": 25,
                    "maxRequestUsage": 500
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            default:
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "WorkosCursorSessionToken=test")

        #expect(snapshot.planPercentUsed == 50.0)
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountName == "Test User")
        #expect(snapshot.requestsUsed == 25)
        #expect(snapshot.requestsLimit == 500)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 5.0)
        #expect(usage.accountEmail(for: .cursor) == "user@example.com")
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

final class CursorStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cursor.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

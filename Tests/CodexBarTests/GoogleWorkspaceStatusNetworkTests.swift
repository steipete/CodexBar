import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct GoogleWorkspaceStatusNetworkTests {
    @Test
    func `fetchWorkspaceStatus uses shared client`() async throws {
        let registered = URLProtocol.registerClass(WorkspaceStatusStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(WorkspaceStatusStubURLProtocol.self)
            }
            WorkspaceStatusStubURLProtocol.handler = nil
            WorkspaceStatusStubURLProtocol.requests = []
        }

        WorkspaceStatusStubURLProtocol.requests = []
        WorkspaceStatusStubURLProtocol.handler = { request in
            WorkspaceStatusStubURLProtocol.requests.append(request)
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let body = Data(#"""
            [
              {
                "begin": "2026-05-10T10:00:00+00:00",
                "end": null,
                "affected_products": [
                  {"title": "Gemini", "id": "npdyhgECDJ6tB66MxXyo"}
                ],
                "most_recent_update": {
                  "when": "2026-05-10T10:15:00+00:00",
                  "status": "SERVICE_OUTAGE",
                  "text": "**Summary**\nGemini API error.\n"
                }
              }
            ]
            """#.utf8)
            return (body, response)
        }

        let status = try await UsageStore.fetchWorkspaceStatus(productID: "npdyhgECDJ6tB66MxXyo")

        #expect(status.indicator == .critical)
        #expect(status.description == "Gemini API error.")
        #expect(WorkspaceStatusStubURLProtocol.requests.count == 1)
        #expect(WorkspaceStatusStubURLProtocol.requests.first?.url?.host == "www.google.com")
    }
}

final class WorkspaceStatusStubURLProtocol: URLProtocol {
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

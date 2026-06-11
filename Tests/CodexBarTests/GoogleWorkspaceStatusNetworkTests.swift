import Foundation
import os
import Testing
@testable import CodexBar

@MainActor
struct GoogleWorkspaceStatusNetworkTests {
    @Test
    func `fetchWorkspaceStatus uses shared client`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
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

        let status = try await UsageStore.fetchWorkspaceStatus(
            productID: "npdyhgECDJ6tB66MxXyo",
            transport: transport)

        #expect(status.indicator == .critical)
        #expect(status.description == "Gemini API error.")
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "www.google.com")
    }

    @Test
    func `fetchWorkspaceStatus decodes off the main thread when called from the main actor`() async throws {
        // The incidents feed can run to hundreds of kilobytes; decoding it on the main
        // actor stalls the UI for 150-340ms per Google-status provider per refresh (#1399).
        let decodedOffMainThread = OSAllocatedUnfairLock(initialState: false)
        let transport = ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data("[]".utf8), response)
        }

        let status = try await UsageStore.fetchWorkspaceStatus(
            productID: "npdyhgECDJ6tB66MxXyo",
            transport: transport,
            beforeDecoding: {
                decodedOffMainThread.withLock { $0 = !Thread.isMainThread }
            })

        #expect(status.indicator == .none)
        #expect(decodedOffMainThread.withLock { $0 })
    }
}

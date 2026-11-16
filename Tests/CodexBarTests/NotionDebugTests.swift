import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NotionDebugTests {
    @Test
    func `debug reports allowances without requesting premium credits`() async {
        let result = await UsageStore.debugNotionLog(
            browserDetection: BrowserDetection(),
            notionCookieSource: .manual,
            notionCookieHeader: "token_v2=synthetic",
            notionWorkspaceID: "space",
            transport: ProviderHTTPTransportHandler { request in
                let endpoint = request.url?.lastPathComponent
                #expect(endpoint != "getAIUsageEligibilityV2")
                let body = endpoint == "getSpaces"
                    ? #"{"user":{"space":{"space":{"value":{"id":"space","name":"Fixture"}}}}}"#
                    : #"{"window":{"window":"6h","used":42,"limit":100},"billingPeriodWindow":{"used":18,"limit":100}}"#
                let url = try #require(request.url)
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            })
        #expect(result == "Notion plugin fetch succeeded\nRolling used: 42.0\nMonthly used: 18.0")
    }

    @Test(.timeLimit(.minutes(1)))
    func `debug deadline cancels a pending required request`() async {
        let (events, cancelled) = AsyncStream<Void>.makeStream()
        let result = await UsageStore.debugNotionLog(
            browserDetection: BrowserDetection(),
            notionCookieSource: .manual,
            notionCookieHeader: "token_v2=synthetic",
            notionWorkspaceID: "space",
            transport: ProviderHTTPTransportHandler { _ in
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cancelled.yield(())
                    throw error
                }
                throw URLError(.timedOut)
            }, probeTimeout: 1)
        #expect(result == "Probe timed out after 1s")
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        cancelled.finish()
    }

    @Test
    func `debug names migrated monthly pools without an optional credit lookup`() async {
        let result = await UsageStore.debugNotionLog(
            browserDetection: BrowserDetection(),
            notionCookieSource: .manual,
            notionCookieHeader: "token_v2=synthetic",
            notionWorkspaceID: "space",
            transport: ProviderHTTPTransportHandler { request in
                let endpoint = request.url?.lastPathComponent
                #expect(endpoint != "getAIUsageEligibilityV2")
                let body = endpoint == "getSpaces"
                    ? #"{"user":{"space":{"space":{"value":{"id":"space","name":"Fixture"}}}}}"#
                    : #"""
                    {"status":"not_applicable","allowances":[
                      {"bucketId":"auto","cadence":"billing_period","state":"resolved","used":20,"limit":100},
                      {"bucketId":"flex","cadence":"billing_period","state":"resolved","used":0,"limit":100}
                    ]}
                    """#
                let url = try #require(request.url)
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            })
        #expect(result == "Notion plugin fetch succeeded\nStandard used: 20.0\nSelect used: 0.0")
    }
}

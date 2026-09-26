import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
struct CursorCostRequestDateTests {
    @Test(arguments: [
        (nil, nil),
        (Date.distantPast, "0"),
        (Date(timeIntervalSince1970: -1), "0"),
        (Date(timeIntervalSince1970: 0), "0"),
        (Date(timeIntervalSince1970: 1_700_000_000), "1700000000000"),
    ] as [(Date?, String?)])
    func `cost requests use a supported lower bound without narrowing modern history`(
        since: Date?, expectedStart: String?) async throws
    {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let body = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(fields["startDate"] as? String == expectedStart)
            #expect(fields["endDate"] as? String == "1800000000000")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"totalUsageEventsCount":0,"usageEventsDisplay":[]}"#.utf8), response)
        }
        let fetcher = CursorUsageEventsFetcher(transport: transport)
        _ = try await fetcher.fetchUsage(cookieHeader: "synthetic", since: since, until: until)
        #expect(await transport.requests().count == 1)
    }
}
#endif

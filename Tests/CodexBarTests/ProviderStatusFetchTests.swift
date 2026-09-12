import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct ProviderStatusFetchTests {
    @Test(arguments: ["2026-09-12T10:00:00Z", "2026-09-12T10:00:00.125Z"])
    func `CLI status retains feed values and its JSON schema`(timestamp: String) async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/v2/status.json")
            #expect(request.timeoutInterval == 10)
            return (
                Data("""
                {"page":{"updated_at":"\(timestamp)"},
                 "status":{"indicator":"major","description":"Service unavailable"}}
                """.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let payload = try #require(await CodexBarCLI.fetchStatus(for: .claude, transport: transport))
        #expect(payload.indicator == .major)
        #expect(payload.description == "Service unavailable")
        #expect(payload.updatedAt != nil)
        #expect(payload.indicator.cliLabel == "Major outage")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any])
        #expect(Set(json.keys) == ["indicator", "description", "updatedAt", "url"])
        #expect(json["indicator"] as? String == "major")
        #expect(json["url"] as? String == ClaudeProviderDescriptor.descriptor.metadata.statusPageURL)
    }

    @Test
    func `status parser keeps unknown indicators and missing metadata`() throws {
        let status = try ProviderStatusFetcher.parseStatuspageStatus(
            data: Data(#"{"status":{"indicator":"new-provider-state"}}"#.utf8))
        #expect(status.indicator == .unknown)
        #expect(status.updatedAt == nil)
        #expect(status.description == nil)
        #expect(throws: DecodingError.self) {
            try ProviderStatusFetcher.parseStatuspageStatus(data: Data(#"""
            {"page":{"updated_at":"bad-date"},"status":{"indicator":"none"}}
            """#.utf8))
        }
    }

    @Test
    func `CLI status still reports a failed fetch as unknown`() async throws {
        let transport = ProviderHTTPTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let payload = try #require(await CodexBarCLI.fetchStatus(for: .claude, transport: transport))
        #expect(payload.indicator == .unknown)
        #expect(payload.description?.isEmpty == false)
        #expect(payload.updatedAt == nil)
    }
}

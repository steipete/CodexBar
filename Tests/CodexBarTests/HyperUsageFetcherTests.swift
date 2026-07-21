import Foundation
import Testing
@testable import CodexBarCore

struct HyperUsageFetcherTests {
    @Test
    func `parses Hypercredit balance into provider cost section`() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = try HyperUsageFetcher._parseSnapshotForTesting(Data(#"{"balance":123.45}"#.utf8), now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.balance == 123.45)
        #expect(usage.identity?.providerID == .hyper)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 123.45)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.currencyCode == "Hypercredits")
        #expect(usage.providerCost?.updatedAt == now)
    }

    @Test
    func `rejects malformed and negative balances`() {
        #expect(throws: HyperUsageError.self) {
            try HyperUsageFetcher._parseSnapshotForTesting(Data(#"{"credits":12}"#.utf8))
        }
        #expect(throws: HyperUsageError.self) {
            try HyperUsageFetcher._parseSnapshotForTesting(Data(#"{"balance":-1}"#.utf8))
        }
    }

    @Test
    func `fetch sends API key only as bearer authorization`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://api.hyper.charm.land/v1/credits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-hyper-key")
            let response = try #require(HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return (Data(#"{"balance":42}"#.utf8), response)
        }

        let snapshot = try await HyperUsageFetcher.fetchUsage(apiKey: "test-hyper-key", transport: transport)
        #expect(snapshot.balance == 42)
    }

    @Test
    func `fetch maps HTTP 401 to missing credentials`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = try #require(HTTPURLResponse(
                url: #require(request.url), statusCode: 401, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        await #expect(throws: HyperUsageError.missingCredentials) {
            try await HyperUsageFetcher.fetchUsage(apiKey: "invalid", transport: transport)
        }
    }

    @Test
    func `fetch maps HTTP 403 to missing credentials`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = try #require(HTTPURLResponse(
                url: #require(request.url), statusCode: 403, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        await #expect(throws: HyperUsageError.missingCredentials) {
            try await HyperUsageFetcher.fetchUsage(apiKey: "invalid", transport: transport)
        }
    }

    @Test
    func `fetch maps HTTP 500 to api error`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = try #require(HTTPURLResponse(
                url: #require(request.url), statusCode: 500, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        await #expect(throws: HyperUsageError.self) {
            try await HyperUsageFetcher.fetchUsage(apiKey: "test-key", transport: transport)
        }
    }
}

struct HyperSettingsReaderTests {
    @Test
    func `reads trims and unquotes HYPER API key`() {
        #expect(HyperSettingsReader.apiKey(environment: ["HYPER_API_KEY": "  'hyper-key'  "]) == "hyper-key")
    }

    @Test
    func `returns nil for missing or blank HYPER API key`() {
        #expect(HyperSettingsReader.apiKey(environment: [:]) == nil)
        #expect(HyperSettingsReader.apiKey(environment: ["HYPER_API_KEY": "  "]) == nil)
    }

    @Test
    func `token resolver reports environment source`() {
        let resolution = ProviderTokenResolver.hyperResolution(environment: ["HYPER_API_KEY": "hyper-key"])
        #expect(resolution?.token == "hyper-key")
        #expect(resolution?.source == .environment)
    }
}

struct HyperProviderDescriptorTests {
    @Test
    func `descriptor is registered with correct defaults`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .hyper)
        #expect(descriptor.metadata.displayName == "Charm Hyper")
        #expect(descriptor.metadata.id == .hyper)
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.metadata.supportsCredits == false)
        #expect(descriptor.metadata.dashboardURL == "https://hyper.charm.land")
        #expect(descriptor.branding.iconStyle == .hyper)
        #expect(descriptor.cli.name == "hyper")
        #expect(descriptor.cli.aliases.isEmpty)
    }
}

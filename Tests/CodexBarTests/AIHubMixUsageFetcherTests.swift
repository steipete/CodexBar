import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct AIHubMixUsageFetcherTests {
    @Test
    func `reads and cleans manage key from access key or token env`() {
        #expect(AIHubMixSettingsReader.apiKey(environment: [
            "AIHUBMIX_ACCESS_KEY": "  \"access-key\"  ",
            "AIHUBMIX_TOKEN": "token-key",
        ]) == "access-key")
        #expect(AIHubMixSettingsReader.apiKey(environment: ["AIHUBMIX_TOKEN": "'token-key'"]) == "token-key")
        #expect(AIHubMixSettingsReader.apiKey(environment: ["AIHUBMIX_ACCESS_KEY": "   "]) == nil)
    }

    @Test
    func `parses documented get-self payload into usd balance`() throws {
        let snapshot = try AIHubMixUsageFetcher.parseSnapshot(data: Self.documentedResponse)
        let usage = snapshot.toUsageSnapshot()

        #expect(abs(snapshot.remainingUSD - 29_071_257.0 / 500_000.0) < 1e-9)
        #expect(abs(snapshot.usedUSD - 286_403_484.0 / 500_000.0) < 1e-9)
        #expect(snapshot.requestCount == 614_422)
        #expect(snapshot.email == "you@example.com")
        #expect(snapshot.displayName == "your_name")
        #expect(usage.primary == nil)
        #expect(usage.identity?.providerID == .aihubmix)
        #expect(usage.loginMethod(for: .aihubmix) == "Balance: \(UsageFormatter.usdString(snapshot.remainingUSD))")
        #expect(usage.details.contains { section in
            section.rows.contains { $0.label == "Used" && $0.value == UsageFormatter.usdString(snapshot.usedUSD) }
        })
    }

    @Test
    func `converts live quota units to 79 cent balance`() throws {
        let snapshot = try AIHubMixUsageFetcher.parseSnapshot(data: Self.liveStyleResponse)

        #expect(abs(snapshot.remainingUSD - 0.788688) < 1e-9)
        #expect(self.usageBalance(snapshot) == "$0.79")
    }

    @Test
    func `fetches self endpoint with raw manage key authorization`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = AIHubMixRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Self.documentedResponse, response)
        }

        let snapshot = try await AIHubMixUsageFetcher.fetchUsage(
            apiKey: "fixture-manage-key",
            environment: [:],
            transport: transport,
            now: now)
        let requests = await recorder.values

        #expect(snapshot.updatedAt == now)
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://aihubmix.com/api/user/self")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "fixture-manage-key")
        #expect(requests[0].httpMethod == "GET")
    }

    @Test
    func `honors https api url override`() async throws {
        let recorder = AIHubMixRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Self.documentedResponse, response)
        }

        _ = try await AIHubMixUsageFetcher.fetchUsage(
            apiKey: "fixture-manage-key",
            environment: ["AIHUBMIX_API_URL": "https://api.aihubmix.com"],
            transport: transport)
        let requests = await recorder.values
        #expect(requests[0].url?.absoluteString == "https://api.aihubmix.com/api/user/self")
    }

    @Test
    func `rejects invalid endpoint override before sending credentials`() async {
        let recorder = AIHubMixRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            throw URLError(.badURL)
        }

        await #expect {
            _ = try await AIHubMixUsageFetcher.fetchUsage(
                apiKey: "fixture-manage-key",
                environment: ["AIHUBMIX_API_URL": "http://example.com"],
                transport: transport)
        } throws: { error in
            guard case AIHubMixSettingsError.invalidEndpointOverride("AIHUBMIX_API_URL") = error else {
                return false
            }
            return true
        }
        #expect(await recorder.values.isEmpty)
    }

    @Test
    func `maps unauthorized http status to invalid credentials`() async {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(), response)
        }

        await #expect {
            _ = try await AIHubMixUsageFetcher.fetchUsage(
                apiKey: "fixture-manage-key",
                environment: [:],
                transport: transport)
        } throws: { error in
            guard case AIHubMixUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `maps unsuccessful payload to api error`() {
        let json = Data(#"{"success":false,"message":"invalid token","data":{}}"#.utf8)
        #expect {
            _ = try AIHubMixUsageFetcher.parseSnapshot(data: json)
        } throws: { error in
            guard case AIHubMixUsageError.apiError("invalid token") = error else { return false }
            return true
        }
    }

    @Test
    func `descriptor registers api strategy token accounts and branding`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .aihubmix)
        #expect(descriptor.metadata.displayName == "AIHubMix")
        #expect(descriptor.metadata.cliName == "aihubmix")
        #expect(descriptor.cli.aliases == ["aihub"])
        #expect(descriptor.metadata.balanceOnly)
        #expect(descriptor.metadata.dashboardURL == "https://aihubmix.com/setting")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-aihubmix")
        #expect(descriptor.fetchPlan.sourceModes == Set([.auto, .api]))
        #expect(descriptor.credentials?.tokenAccountSupport != nil)
    }

    private func usageBalance(_ snapshot: AIHubMixUsageSnapshot) -> String {
        UsageFormatter.usdString(snapshot.remainingUSD)
    }

    private static let documentedResponse = Data(
        """
        {
          "data": {
            "username": "your_name",
            "display_name": "your_name",
            "role": 1,
            "status": 1,
            "email": "you@example.com",
            "quota": 29071257,
            "used_quota": 286403484,
            "request_count": 614422,
            "group": "default",
            "aff_code": "XXXX",
            "notify": true,
            "quota_remind_threshold": 10000000,
            "notify_email": "you@example.com",
            "ext": ""
          },
          "message": "",
          "success": true
        }
        """.utf8)

    private static let liveStyleResponse = Data(
        """
        {
          "data": {
            "username": "fixture",
            "display_name": "fixture",
            "status": 1,
            "email": "fixture@example.com",
            "quota": 394344,
            "used_quota": 3105656,
            "request_count": 4931,
            "group": "default"
          },
          "message": "",
          "success": true
        }
        """.utf8)
}

private actor AIHubMixRequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.values.append(request)
    }
}

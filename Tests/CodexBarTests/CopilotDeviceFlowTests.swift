import CodexBarCore
import Foundation
import Testing

struct CopilotDeviceFlowTests {
    @Test
    func `slow down persists across subsequent pending responses`() async throws {
        let probe = CopilotPollingProbe()
        let flow = CopilotDeviceFlow(transport: ProviderHTTPTransportHandler { request in
            let body = await probe.nextResponse()
            let url = try #require(request.url)
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let token = try await flow.pollForToken(deviceCode: "synthetic", interval: 1)
        #expect(token == "synthetic-token")
        let times = await probe.times
        #expect(times.count == 3)
        #expect(times[1].duration(to: times[2]) >= .seconds(6))
    }

    @Test
    func `expired device code stops without polling`() async {
        let flow = CopilotDeviceFlow(transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Expired device code must not be sent")
            throw URLError(.badURL)
        })
        await #expect(throws: URLError(.timedOut)) {
            try await flow.pollForToken(deviceCode: "expired", interval: 5, expiresIn: 0)
        }
    }

    @Test
    func `cancelling device login interrupts polling sleep`() async {
        let flow = CopilotDeviceFlow(transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Cancelled login must not poll")
            throw URLError(.badURL)
        })
        let task = Task { try await flow.pollForToken(deviceCode: "cancelled", interval: 300) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func `malformed token response fails instead of polling forever`() async {
        let flow = CopilotDeviceFlow(transport: ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("{}".utf8), response)
        })
        await #expect(throws: URLError(.cannotParseResponse)) {
            try await flow.pollForToken(deviceCode: "synthetic", interval: 1)
        }
    }

    @Test(arguments: ["github.com", "GITHUB.COM.", "https://github.com:443/login"])
    func `default https issuer spellings remain public GitHub`(_ host: String) {
        #expect(CopilotDeviceFlow(enterpriseHost: host).deviceCodeURL?.absoluteString ==
            "https://github.com/login/device/code")
        #expect(CopilotUsageFetcher.apiHost(enterpriseHost: host) == "api.github.com")
    }

    @Test
    func `enterprise issuer preserves a nondefault port without a trailing dns dot`() {
        #expect(CopilotUsageFetcher.apiHost(enterpriseHost: "https://example.ghe.com.:8443/path") ==
            "api.example.ghe.com:8443")
    }

    @Test
    func `prefers verification uri complete when available`() throws {
        let response = try JSONDecoder().decode(
            CopilotDeviceFlow.DeviceCodeResponse.self,
            from: Data(
                """
                {
                  "device_code": "device-code",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "verification_uri_complete": "https://github.com/login/device?user_code=ABCD-EFGH",
                  "expires_in": 900,
                  "interval": 5
                }
                """.utf8))

        #expect(response.verificationURLToOpen == "https://github.com/login/device?user_code=ABCD-EFGH")
    }

    @Test
    func `falls back to verification uri when complete url missing`() throws {
        let response = try JSONDecoder().decode(
            CopilotDeviceFlow.DeviceCodeResponse.self,
            from: Data(
                """
                {
                  "device_code": "device-code",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "expires_in": 900,
                  "interval": 5
                }
                """.utf8))

        #expect(response.verificationURLToOpen == "https://github.com/login/device")
    }

    @Test
    func `device flow uses github by default`() throws {
        let flow = CopilotDeviceFlow()
        let deviceCodeURL = try #require(flow.deviceCodeURL)
        let accessTokenURL = try #require(flow.accessTokenURL)

        #expect(deviceCodeURL.absoluteString == "https://github.com/login/device/code")
        #expect(accessTokenURL.absoluteString == "https://github.com/login/oauth/access_token")
    }

    @Test
    func `device flow uses enterprise host`() throws {
        let flow = CopilotDeviceFlow(enterpriseHost: "https://octocorp.ghe.com/login")
        let deviceCodeURL = try #require(flow.deviceCodeURL)
        let accessTokenURL = try #require(flow.accessTokenURL)

        #expect(deviceCodeURL.absoluteString == "https://octocorp.ghe.com/login/device/code")
        #expect(accessTokenURL.absoluteString == "https://octocorp.ghe.com/login/oauth/access_token")
    }

    @Test
    func `device flow rejects invalid enterprise host without crashing`() {
        let flow = CopilotDeviceFlow(enterpriseHost: "foo bar")

        #expect(flow.deviceCodeURL == nil)
        #expect(flow.accessTokenURL == nil)
    }

    @Test
    func `device flow preserves enterprise host port`() throws {
        let flow = CopilotDeviceFlow(enterpriseHost: "https://octocorp.ghe.com:8443/login")
        let deviceCodeURL = try #require(flow.deviceCodeURL)
        let accessTokenURL = try #require(flow.accessTokenURL)

        #expect(deviceCodeURL.absoluteString == "https://octocorp.ghe.com:8443/login/device/code")
        #expect(accessTokenURL.absoluteString == "https://octocorp.ghe.com:8443/login/oauth/access_token")
    }

    @Test
    func `usage url uses enterprise api host`() throws {
        let defaultURL = try #require(CopilotUsageFetcher.usageURL(enterpriseHost: nil))
        let enterpriseURL = try #require(CopilotUsageFetcher.usageURL(enterpriseHost: "octocorp.ghe.com"))
        let enterprisePortURL = try #require(CopilotUsageFetcher.usageURL(enterpriseHost: "octocorp.ghe.com:8443"))

        #expect(defaultURL.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(enterpriseURL.absoluteString == "https://api.octocorp.ghe.com/copilot_internal/user")
        #expect(enterprisePortURL.absoluteString == "https://api.octocorp.ghe.com:8443/copilot_internal/user")
    }
}

private actor CopilotPollingProbe {
    var times: [ContinuousClock.Instant] = []

    func nextResponse() -> String {
        self.times.append(.now)
        switch self.times.count {
        case 1: return #"{"error":"slow_down"}"#
        case 2: return #"{"error":"authorization_pending"}"#
        default: return #"{"access_token":"synthetic-token","token_type":"bearer","scope":"read:user"}"#
        }
    }
}

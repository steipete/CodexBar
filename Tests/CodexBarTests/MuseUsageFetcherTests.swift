import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MuseUsageFetcherTests {
    @Test
    func `parses live mint subscription windows`() throws {
        let now = Date(timeIntervalSince1970: 1_788_580_000)
        let snapshot = try MuseUsageFetcher._parseMintResponseForTesting(Self.liveMintData, now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.planName == "Muse Code Power Usage")
        #expect(snapshot.accountEmail == "ada@example.com")
        #expect(snapshot.windowUsedPercent == 96)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.windowResetsAt == Date(timeIntervalSince1970: 1_788_599_502))
        #expect(snapshot.weeklyUsedPercent == 96)
        #expect(snapshot.weeklyResetsAt == Date(timeIntervalSince1970: 1_788_739_200))
        #expect(usage.primary?.usedPercent == 96)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 96)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.identity?.providerID == .muse)
        #expect(usage.identity?.accountEmail == "ada@example.com")
        #expect(usage.identity?.loginMethod == "Muse Code Power Usage")
        #expect(usage.dataConfidence == .exact)
        #expect(!(usage.identity?.loginMethod?.contains("Visa") ?? false))
        #expect(usage.details.contains { $0.title == "Muse Code subscription" })
    }

    @Test
    func `rejects inactive subscription instead of fabricating quota`() {
        #expect(throws: MuseUsageError.noSubscription) {
            try MuseUsageFetcher._parseMintResponseForTesting(Self.inactiveMintData)
        }
    }

    @Test
    func `rejects payment-required mint`() {
        #expect(throws: MuseUsageError.paymentRequired) {
            try MuseUsageFetcher._parseMintResponseForTesting(Self.paymentRequiredMintData)
        }
    }

    @Test
    func `mints usage with device-code bearer and does not send inference keys`() async throws {
        let recorder = MuseRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Self.liveMintData, response)
        }

        let snapshot = try await MuseUsageFetcher._fetchUsageForTesting(
            accessToken: "dca:fixture-token",
            transport: transport,
            now: Date(timeIntervalSince1970: 1))
        let requests = await recorder.values

        #expect(snapshot.windowUsedPercent == 96)
        #expect(requests.count == 1)
        #expect(requests[0].url == MuseUsageFetcher.mintURL)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer dca:fixture-token")
        #expect(requests[0].value(forHTTPHeaderField: "x-api-version") == "1.0.0")
        #expect(String(data: requests[0].httpBody ?? Data(), encoding: .utf8) == "{}")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.contains("LLM") != true)
    }

    @Test
    func `rejects inference keys as mint credentials`() async {
        let recorder = MuseRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            Issue.record("Must not send LLM| keys to /muse-code/key")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(), response)
        }

        await #expect {
            _ = try await MuseUsageFetcher._fetchUsageForTesting(
                accessToken: "LLM|not-a-device-token",
                transport: transport)
        } throws: { error in
            guard case MuseUsageError.invalidCredentials = error else { return false }
            return true
        }
        #expect(await recorder.values.isEmpty)
    }

    @Test
    func `maps unauthorized mint to invalid credentials`() async {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"title":"Authentication Error"}"#.utf8), response)
        }

        await #expect {
            _ = try await MuseUsageFetcher._fetchUsageForTesting(
                accessToken: "dca:expired",
                transport: transport)
        } throws: { error in
            guard case MuseUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `extracts device-code token from Muse Keychain payload`() throws {
        let data = Data(
            """
            {"secret_schema_version":1,"api_key":"LLM|not-for-mint","access_token":"dca:stored-token"}
            """.utf8)
        #expect(try MuseCredentials.accessToken(fromKeychainPayload: data) == "dca:stored-token")
    }

    @Test
    func `rejects Keychain payloads that only have an inference key`() {
        let data = Data(
            """
            {"secret_schema_version":1,"api_key":"LLM|not-for-mint","access_token":"LLM|also-wrong"}
            """.utf8)
        #expect(throws: MuseUsageError.invalidCredentials) {
            _ = try MuseCredentials.accessToken(fromKeychainPayload: data)
        }
    }

    @Test
    func `treats oauth auth json as a login even without an inline token`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try Data(
            """
            {"schema_version":2,"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}
            """.utf8).write(to: authURL)

        let environment = ["MUSE_AUTH_PATH": authURL.path]
        #expect(MuseCredentials.hasLogin(environment: environment, homeDirectory: directory))
    }

    @Test
    func `descriptor registers oauth strategy and branding`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .muse)
        #expect(descriptor.metadata.displayName == "Muse Code")
        #expect(descriptor.metadata.shortDisplayName == "Muse Code")
        #expect(descriptor.metadata.sessionLabel == "5 hours")
        #expect(descriptor.metadata.weeklyLabel == "Weekly")
        #expect(descriptor.metadata.dashboardURL == "https://dev.meta.ai")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-muse")
        #expect(descriptor.fetchPlan.sourceModes == Set([.auto, .oauth]))
        #expect(descriptor.cli.name == "muse")
        #expect(descriptor.cli.aliases.contains("muse-code") == true)
        #expect(descriptor.credentials != nil)
    }

    @Test
    func `rejects out-of-range window duration instead of trapping`() {
        #expect {
            try MuseUsageFetcher._parseMintResponseForTesting(Self.oversizedDurationMintData)
        } throws: { error in
            guard case MuseUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test(arguments: ["window", "weekly"])
    func `oversized reset timestamps preserve usage without unsafe countdowns`(_ windowName: String) throws {
        var payload = try #require(JSONSerialization.jsonObject(with: Self.liveMintData) as? [String: Any])
        var windows = try #require(payload["subs_usage"] as? [String: Any])
        var window = try #require(windows[windowName] as? [String: Any])
        window["resets_at"] = 1e30
        windows[windowName] = window
        payload["subs_usage"] = windows
        let data = try JSONSerialization.data(withJSONObject: payload)
        let now = Date(timeIntervalSince1970: 1_788_580_000)
        let usage = try MuseUsageFetcher._parseMintResponseForTesting(data, now: now).toUsageSnapshot()
        let affected = try #require(windowName == "window" ? usage.primary : usage.secondary)
        let unaffected = try #require(windowName == "window" ? usage.secondary : usage.primary)

        #expect(affected.usedPercent == 96)
        try #require(affected.resetsAt == nil)
        #expect(UsageFormatter.resetLine(for: affected, style: .countdown, now: now) == nil)
        #expect(unaffected.resetsAt != nil)
        #expect(UsageFormatter.resetLine(for: unaffected, style: .countdown, now: now) != nil)
    }

    @Test
    func `descriptor reports oauth login without api key support`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .muse)
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.supportsAPIKeyOverride == false)
        #expect(credentials.requiresAPIKeyForAPISource == false)
        #expect(credentials.unavailableMessage(environment: [:])?.contains("muse login") == true)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try Data(
            """
            {"schema_version":2,"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}
            """.utf8).write(to: authURL)

        let summary = credentials.diagnosticAuthSummary(
            account: nil,
            config: nil,
            environment: ["MUSE_AUTH_PATH": authURL.path],
            settings: nil)
        #expect(summary.configured == true)
        #expect(summary.modes == ["oauth"])

        let missing = credentials.diagnosticAuthSummary(
            account: nil,
            config: nil,
            environment: ["MUSE_AUTH_PATH": directory.appendingPathComponent("missing.json").path],
            settings: nil)
        #expect(missing.configured == false)
        #expect(missing.modes.isEmpty)
    }

    private static let liveMintData = Data(
        """
        {
          "api_key": "LLM|redacted",
          "base_url": "https://api.meta.ai/v1",
          "has_payment_method": true,
          "require_payment": false,
          "is_subs_active": true,
          "can_subscribe": false,
          "show_subs_upsell": true,
          "user_full_name": "Ada Lovelace",
          "user_email": "ada@example.com",
          "payment_method": "Visa-0000",
          "action_url": null,
          "subs_tier_id": "123",
          "subs_tier_name": "Muse Code Power Usage",
          "is_subs_upgrade_available": false,
          "subs_usage": {
            "window": {
              "used_percent": 96,
              "window_duration_mins": 300,
              "resets_at": 1788599502
            },
            "weekly": {
              "used_percent": 96,
              "resets_at": 1788739200
            },
            "tier": "123"
          }
        }
        """.utf8)

    private static let oversizedDurationMintData = Data(
        """
        {
          "require_payment": false,
          "is_subs_active": true,
          "subs_tier_name": "Muse Code Power Usage",
          "user_email": "ada@example.com",
          "subs_usage": {
            "window": {
              "used_percent": 96,
              "window_duration_mins": 1e30,
              "resets_at": 1788599502
            },
            "weekly": {
              "used_percent": 96,
              "resets_at": 1788739200
            }
          }
        }
        """.utf8)

    private static let inactiveMintData = Data(
        """
        {
          "require_payment": false,
          "is_subs_active": false,
          "subs_tier_name": null,
          "subs_usage": null
        }
        """.utf8)

    private static let paymentRequiredMintData = Data(
        """
        {
          "require_payment": true,
          "is_subs_active": false,
          "action_url": "https://dev.meta.ai"
        }
        """.utf8)
}

private actor MuseRequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.values.append(request)
    }
}

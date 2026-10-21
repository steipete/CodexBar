import Foundation
import Testing
@testable import CodexBarCore

struct GrokACPUnknownUsageTests {
    @Test
    func `active ACP period with omitted percentage adopts validated implicit zero`() async throws {
        let fixture = try Self.makeFixture(credentials: .valid, prepaidCents: 123)
        defer { fixture.cleanup() }
        var probe = GrokStatusProbe()
        probe.localSummary = { _ in nil }
        probe.settingsTransport = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            if request.url == GrokCLISettingsFetcher.defaultEndpoint {
                return (Data("{}".utf8), response)
            }
            #expect(request.url == GrokWebBillingFetcher.defaultEndpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            // The bearer response validates zero but must not replace the ACP reset or wallet.
            return (Self.zeroUsagePayload(endingAt: fixture.periodEnd.addingTimeInterval(-90)), response)
        }
        let snapshot = try await probe.fetch(env: fixture.environment)
        let usage = snapshot.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(primary.usedPercent == 0)
        #expect(primary.windowMinutes == 10080)
        #expect(primary.resetsAt == fixture.periodEnd)
        #expect(usage.providerCost?.balance == 1.23)
        #expect(snapshot.webBilling?.usedPercentIsImplicitZero == true)
    }

    @Test
    func `published ACP usage skips enrichment`() async throws {
        let fixture = try Self.makeFixture(credentials: .valid, publishedPercent: 5)
        defer { fixture.cleanup() }
        var probe = GrokStatusProbe()
        probe.localSummary = { _ in nil }
        probe.settingsTransport = ProviderHTTPTransportHandler { request in
            #expect(request.url == GrokCLISettingsFetcher.defaultEndpoint)
            return try (Data("{}".utf8), #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect(try await probe.fetch(env: fixture.environment).toUsageSnapshot().primary?.usedPercent == 5)
    }

    @Test(arguments: [CredentialsMode.valid, .expired, .missing])
    func `unavailable enrichment preserves prepaid billing`(_ mode: CredentialsMode) async throws {
        let fixture = try Self.makeFixture(credentials: mode, prepaidCents: 123)
        defer { fixture.cleanup() }
        var probe = GrokStatusProbe()
        probe.localSummary = { _ in nil }
        probe.settingsTransport = ProviderHTTPTransportHandler { request in
            if request.url == GrokWebBillingFetcher.defaultEndpoint {
                #expect(mode == .valid)
            }
            throw URLError(.timedOut)
        }
        let usage = try await probe.fetch(env: fixture.environment).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.balance == 1.23)
    }

    private static func zeroUsagePayload(endingAt end: Date) -> Data {
        func varint(_ number: UInt64) -> Data {
            var number = number
            var bytes = Data()
            while number >= 0x80 {
                bytes.append(UInt8(number & 0x7F) | 0x80)
                number >>= 7
            }
            bytes.append(UInt8(number))
            return bytes
        }
        func message(_ field: UInt8, _ data: Data) -> Data {
            Data([field << 3 | 2, UInt8(data.count)]) + data
        }
        let start = Data([0x08]) + varint(UInt64(end.timeIntervalSince1970) - 7 * 86400)
        let finish = Data([0x08]) + varint(UInt64(end.timeIntervalSince1970))
        let period = Data([0x08, 0x02]) + message(2, start) + message(3, finish)
        return message(1, message(8, period))
    }

    enum CredentialsMode: Sendable {
        case valid, expired, missing
    }

    private struct ACPFixture: Sendable {
        let root: URL
        let environment: [String: String]
        let periodEnd: Date

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    private static func makeFixture(
        credentials: CredentialsMode,
        prepaidCents: Int? = nil,
        publishedPercent: Double? = nil) throws -> ACPFixture
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-acp-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = Date()
        let periodStart = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - 3 * 86400)
        let periodEnd = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) + 4 * 86400)
        let startString = formatter.string(from: periodStart)
        let endString = formatter.string(from: periodEnd)

        if credentials != .missing {
            let expiresAt = credentials == .expired ? "2000-01-01T00:00:00Z" : "2099-01-01T00:00:00Z"
            let auth: [String: Any] = [
                "https://auth.x.ai::fake-client": [
                    "key": "synthetic-token",
                    "refresh_token": "synthetic-refresh",
                    "email": "grok@example.com",
                    "auth_mode": "oidc",
                    "principal_type": "User",
                    "expires_at": expiresAt,
                ],
            ]
            try JSONSerialization.data(withJSONObject: auth)
                .write(to: root.appendingPathComponent("auth.json"))
        }

        var config: [String: Any] = [
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": startString,
                "end": endString,
            ],
        ]
        if let prepaidCents {
            config["prepaidBalance"] = ["val": prepaidCents]
        }
        if let publishedPercent {
            config["creditUsagePercent"] = publishedPercent
        }
        let billing: [String: Any] = ["config": config, "subscription_tier": "SuperGrok Heavy"]

        func reply(id: Int, result: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(
                withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            return try #require(String(bytes: data, encoding: .utf8))
        }
        let initialize = try reply(id: 1, result: [:])
        let billingReply = try reply(id: 2, result: billing)
        let binary = root.appendingPathComponent("grok-fixture")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            printf '%s\\n' 'grok synthetic-version'
            exit 0
        fi
        IFS= read -r initialize_request
        printf '%s\\n' '\(initialize)'
        IFS= read -r billing_request || exit 0
        printf '%s\\n' '\(billingReply)'
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        return try ACPFixture(
            root: root,
            environment: [
                "HOME": root.path,
                "GROK_HOME": root.path,
                "GROK_CLI_PATH": binary.path,
                "PATH": "/usr/bin:/bin",
            ],
            periodEnd: #require(ISO8601DateParser.parse(endString)))
    }
}

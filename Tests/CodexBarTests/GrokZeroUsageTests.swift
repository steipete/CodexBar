import Foundation
import Testing
@testable import CodexBarCore

struct GrokZeroUsageTests {
    @Test
    func `reported weekly frame restores zero usage and preserves proxy metadata`() async throws {
        // Captured billing shape from #3261: omitted percentage, fractional timestamps, active weekly period.
        let frame = Self.bytes(
            "00000000440a4212001a00220b0887a8c6d40610f0d7dd142a0b08879debd40610f0d7dd14"
                + "421c0802120b0887a8c6d40610f0d7dd141a0b08879debd40610f0d7dd14580162006801"
                + "800000000f677270632d7374617475733a300d0a")
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(frame, now: Self.now)
        let result = try await Self.resolve(parsed)

        #expect(parsed.usedPercent == 0)
        #expect(parsed.usedPercentIsImplicitZero)
        #expect(!parsed.usedPercentIsWirePublished)
        #expect(result.snapshot.usedPercent == 0)
        #expect(result.snapshot.usedPercentIsImplicitZero)
        #expect(!result.snapshot.usedPercentIsWirePublished)
        #expect(result.snapshot.resetsAt == Self.proxyReset)
        #expect(result.snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(result.sourceLabel == "grok-web")

        let enriched = result.snapshot.applying(subscriptionTier: "SuperGrok")
        #expect(enriched.usedPercentIsImplicitZero)
        #expect(!enriched.usedPercentIsWirePublished)
        let usage = GrokUsageSnapshot(
            billing: nil,
            webBilling: enriched,
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Self.now)
        #expect(usage.toUsageSnapshot().primary?.usedPercent == 0)
    }

    @Test(arguments: [1, 2])
    func `complete monthly and weekly periods support implicit zero`(periodType: UInt8) async throws {
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(
            Self.payload(periodType: periodType), now: Self.now)

        #expect(parsed.usedPercentIsImplicitZero)
        #expect(try await Self.resolve(parsed).snapshot.usedPercent == 0)
    }

    @Test(arguments: [
        Data([0x00]), // Invalid field key.
        Data([0x0D, 0x00]), // Truncated percentage.
        Data([0x72, 0x04, 0x08]), // Truncated nested message.
        Data([0x70, 0x80]), // Truncated varint.
    ])
    func `malformed frames cannot turn unknown usage into zero`(suffix: Data) async throws {
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(Self.payload(suffix: suffix), now: Self.now)

        #expect(!parsed.usedPercentIsImplicitZero)
        #expect(try await Self.resolve(parsed).snapshot.usedPercent == nil)
    }

    @Test(arguments: [0, 3])
    func `unknown period types cannot supply implicit zero`(periodType: UInt8) throws {
        #expect(throws: GrokWebBillingError.self) {
            try GrokWebBillingFetcher.parseGRPCWebResponse(Self.payload(periodType: periodType), now: Self.now)
        }
    }

    @Test
    func `future and incomplete periods cannot supply implicit zero`() async throws {
        for payload in [Self.payload(start: 1_800_000_000), Self.payload(includeStart: false)] {
            let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(payload, now: Self.now)
            #expect(!parsed.usedPercentIsImplicitZero)
            #expect(try await Self.resolve(parsed).snapshot.usedPercent == nil)
        }
    }

    @Test
    func `expired periods cannot supply implicit zero`() {
        #expect(throws: GrokWebBillingError.self) {
            try GrokWebBillingFetcher.parseGRPCWebResponse(Self.payload(), now: Self.proxyReset)
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_788_000_000)
    private static let proxyReset = Date(timeIntervalSince1970: 1_900_000_000)
    private static let credentials = GrokCredentials(
        accessToken: "synthetic-token",
        refreshToken: nil,
        scope: "https://auth.x.ai::test",
        authMode: "oidc",
        userId: nil,
        email: nil,
        firstName: nil,
        lastName: nil,
        teamId: nil,
        oidcIssuer: nil,
        oidcClientId: nil,
        expiresAt: .distantFuture,
        createTime: nil)

    private static func resolve(_ snapshot: GrokWebBillingSnapshot) async throws -> (
        snapshot: GrokWebBillingSnapshot, sourceLabel: String, authenticatedByAuthFile: Bool)
    {
        try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(usedPercent: nil, resetsAt: self.proxyReset, subscriptionTier: "SuperGrok Heavy"),
            credentials: self.credentials,
            grpcBilling: { _ in snapshot })
    }

    private static func payload(
        periodType: UInt8 = 2,
        start: UInt64 = 1_787_000_000,
        includeStart: Bool = true,
        suffix: Data = Data()) -> Data
    {
        let startTimestamp = Data([0x08]) + Self.varint(start)
        let endTimestamp = Data([0x08]) + Self.varint(1_789_000_000)
        var period = Data([0x08, periodType])
        if includeStart {
            period += Data([0x12, UInt8(startTimestamp.count)]) + startTimestamp
        }
        period += Data([0x1A, UInt8(endTimestamp.count)]) + endTimestamp
        let config = Data([0x42, UInt8(period.count)]) + period + suffix
        return Data([0x0A, UInt8(config.count)]) + config
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }

    private static func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
}

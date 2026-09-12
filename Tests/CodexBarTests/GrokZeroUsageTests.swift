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

    @Test(arguments: Self.malformedSuffixes)
    func `malformed frames cannot turn unknown usage into zero`(suffix: Data) async throws {
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(Self.payload(suffix: suffix), now: Self.now)

        #expect(!parsed.usedPercentIsImplicitZero)
        #expect(try await Self.resolve(parsed).snapshot.usedPercent == nil)
    }

    @Test(arguments: [
        Self.fixed64Field(tag: [0xF9, 0xFF, 0xFF, 0xFF, 0x0F]), // Highest valid field number.
        Data([0x70]) + Self.varint(.max), // A valid UInt64.max scalar.
    ])
    func `valid unknown fields preserve implicit zero`(suffix: Data) async throws {
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(Self.payload(suffix: suffix), now: Self.now)

        #expect(parsed.usedPercentIsImplicitZero)
        #expect(try await Self.resolve(parsed).snapshot.usedPercent == 0)
    }

    @Test(arguments: [false, true], Self.opaquePayloads)
    func `unknown byte fields cannot invalidate or invent billing values`(
        atRoot: Bool, bytes: Data) async throws
    {
        let opaqueField = Self.message(path: [14], contents: bytes)
        let payload = atRoot ? Self.payload() + opaqueField : Self.payload(suffix: opaqueField)
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(payload, now: Self.now)

        #expect(parsed.usedPercent == 0)
        #expect(parsed.usedPercentIsImplicitZero)
        #expect(!parsed.usedPercentIsWirePublished)
        #expect(parsed.resetsAt == Date(timeIntervalSince1970: 1_789_000_000))
        #expect(try await Self.resolve(parsed).snapshot.usedPercent == 0)
    }

    @Test(arguments: Self.billingMessagePaths)
    func `malformed known messages still prevent implicit zero`(path: [UInt64]) async throws {
        let malformedMessage = Self.message(path: path, contents: Self.fixed64Field(tag: [0x01]))
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(
            Self.payload() + malformedMessage, now: Self.now)

        #expect(!parsed.usedPercentIsImplicitZero)
        #expect(try await Self.resolve(parsed).snapshot.usedPercent == nil)
    }

    @Test
    func `historical period timestamps remain readable without becoming current usage`() throws {
        let timestamp = Data([0x08]) + Self.varint(1_789_000_000)
        let payload = Self.message(path: [1, 6, 3, 3], contents: timestamp)
        let parsed = try GrokWebBillingFetcher.parseGRPCWebResponse(payload, now: Self.now)

        #expect(parsed.resetsAt == Date(timeIntervalSince1970: 1_789_000_000))
        #expect(!parsed.usedPercentIsImplicitZero)
        #expect(!parsed.usedPercentIsWirePublished)
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

    private static let malformedSuffixes: [Data] = [
        Data([0x00]), // Invalid field key.
        Self.fixed64Field(tag: [0x01]), // Invalid field zero with a complete fixed64 value.
        Data([0x02, 0x00]), // Invalid field zero with an empty length-delimited value.
        Self.fixed64Field(tag: [0x81, 0x80, 0x80, 0x80, 0x10]), // Field number exceeds 29 bits.
        // Overflowing varint must not truncate to a valid fixed64 tag.
        Self.fixed64Field(tag: [0x89, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]),
        Data([0x0D, 0x00]), // Truncated percentage.
        Data([0x72, 0x04, 0x08]), // Truncated unknown length-delimited field.
        Data([0x70, 0x80]), // Truncated varint.
    ]

    private static let opaquePayloads: [Data] = [
        Self.fixed64Field(tag: [0x01]), // Valid opaque bytes, not a valid protobuf message.
        Data([0x0D, 0x00, 0x00, 0x14, 0x42]), // Looks like a published 37% usage field.
        Data([0x08]) + Self.varint(1_788_500_000), // Looks like an earlier future reset.
    ]

    private static let billingMessagePaths: [[UInt64]] = [
        [1],
        [1, 2], [1, 3], [1, 4], [1, 5], [1, 6], [1, 7], [1, 8], [1, 12],
        [1, 6, 1], [1, 6, 2], [1, 6, 3], [1, 8, 2], [1, 8, 3],
        [1, 6, 3, 2], [1, 6, 3, 3],
    ]

    private static func message(path: [UInt64], contents: Data) -> Data {
        path.reversed().reduce(contents) { payload, field in
            Self.varint((field << 3) | 2) + Self.varint(UInt64(payload.count)) + payload
        }
    }

    private static func fixed64Field(tag: [UInt8]) -> Data {
        Data(tag + [UInt8](repeating: 0, count: 8))
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

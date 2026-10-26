import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct KimiGiftBalanceTests {
    @Test(arguments: [false, true])
    func `gift balances survive monthly exhaustion through web and API enrichment`(api: Bool) async throws {
        let usage = try await Self.fetch(api: api, stats: Self.stats)
        let rows = usage.details.flatMap(\.rows)
        let gift = try #require(rows.first { $0.label == "Invite to Earn Credit" })
        #expect(gift.value == "75% left")
        #expect(gift.progress?.used == 0.2524)
        #expect(gift.secondaryValue?.hasPrefix("Expires ") == true)
        #expect(!rows.contains { $0.label == "Expired grant" })
        #expect(usage.extraRateWindows?.map(\.id) == ["kimi-monthly"])
        let model = try KimiMonthlyBlockingTests.model(usage)
        let displayed = try #require(model.providerDetails.flatMap(\.rows).first { $0.label == gift.label })
        #expect(displayed.value == gift.value)
        #expect(displayed.progress == gift.progress)
        #expect(!model.metrics.contains { $0.title == gift.label })
    }

    @Test
    func `malformed optional gifts retain subscription usage`() async throws {
        let usage = try await Self.fetch(api: false, stats: """
        {"subscriptionBalance":{"amountUsedRatio":0.5},"giftBalances":{"unexpected":true}}
        """)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 50)
        #expect(usage.details.isEmpty)
    }

    static func fetch(
        api: Bool,
        stats: String,
        codeAPI: String = #"{"usage":{"limit":"100","used":"25","remaining":"75"}}"#) async throws -> UsageSnapshot
    {
        let now = try #require(ISO8601DateParser.parse("2026-10-21T15:00:00Z"))
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let json: String
            if url.path.hasSuffix("/GetSubscriptionStats") {
                json = stats
            } else if url.path.hasSuffix("/GetSubscription") {
                json = "{}"
            } else if url.path.hasSuffix("/usages") {
                json = codeAPI
            } else {
                #expect(url.path.hasSuffix("/GetUsages"))
                json = #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25"}}]}"#
            }
            return try (Data(json.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let snapshot = if api {
            try await KimiUsageFetcher.fetchCodeAPIUsage(
                apiKey: "fixture-api-key", webAuthToken: "fixture-web-token", now: now, transport: transport)
        } else {
            try await KimiUsageFetcher.fetchUsage(authToken: "fixture-web-token", now: now, transport: transport)
        }
        return snapshot.toUsageSnapshot()
    }

    /// #4691's reported shape, with synthetic names for the expired pool and no grant identifiers.
    static let stats = """
    {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION",
      "amountUsedRatio":1,"expireTime":"2026-10-22T00:00:00Z"},
     "giftBalances":[
      {"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":1,
       "expireTime":"2026-10-23T00:00:00Z","displayName":"Reservation Bonus"},
      {"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":0.2524,"kimiCodeUsedRatio":0.1465,
       "expireTime":"2026-12-31T15:59:59Z","displayName":"Invite to Earn Credit"},
      {"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":0,
       "expireTime":"2026-10-20T00:00:00Z","displayName":"Expired grant"}]}
    """
}

struct KimiWebLanguageTests {
    @Test(arguments: [
        ("zh-Hans", "zh-CN"),
        ("zh-Hant-TW", "zh-CN"),
        ("en-US", "en-US"),
        ("ja-JP", "en-US"),
        ("en_US_POSIX", "en-US"),
    ])
    func `requests Chinese gift names only for Chinese UI`(identifier: String, expected: String) {
        #expect(KimiUsageFetcher.webLanguage(for: Locale(identifier: identifier)) == expected)
    }
}

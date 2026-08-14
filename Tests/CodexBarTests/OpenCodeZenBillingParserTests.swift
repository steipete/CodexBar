import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeZenBillingParserTests {
    private func loadFixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "Fixtures/Providers/OpenCode"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func `parses monthly spend from pay as you go billing payload`() throws {
        let info = try #require(OpenCodeZenBillingParser.parse(text: self.loadFixture("billing-pay-as-you-go")))

        #expect(info.monthlyUsageUSD == 15)
        #expect(info.monthlyLimitUSD == 20)
        #expect(info.balanceUSD == 12.5)
        #expect(info.hasSubscription == false)
        #expect(info.usageUpdatedAt != nil)
    }

    @Test
    func `parses billing object delivered as JSON`() {
        let text = """
        {"customerID":"cus_TEST","balance":500000000,"monthlyLimit":10,
         "monthlyUsage":250000000,"subscription":null}
        """
        let info = OpenCodeZenBillingParser.parse(text: text)

        #expect(info?.monthlyUsageUSD == 2.5)
        #expect(info?.monthlyLimitUSD == 10)
        #expect(info?.balanceUSD == 5)
    }

    @Test
    func `reports no limit when the workspace has no monthly limit`() {
        let text = #"{"customerID":"cus_TEST","balance":100000000,"monthlyLimit":null,"monthlyUsage":300000000}"#
        let info = OpenCodeZenBillingParser.parse(text: text)

        #expect(info?.monthlyUsageUSD == 3)
        #expect(info?.monthlyLimitUSD == nil)
    }

    @Test
    func `detects a legacy workspace that still carries a subscription`() {
        let text = #"{"customerID":"cus_TEST","monthlyUsage":100000000,"subscription":{"id":"sub_TEST"}}"#
        let info = OpenCodeZenBillingParser.parse(text: text)

        #expect(info?.hasSubscription == true)
    }

    @Test
    func `ignores payloads without a customer object`() {
        #expect(OpenCodeZenBillingParser.parse(text: #"{"monthlyUsage":1500000000}"#) == nil)
        #expect(OpenCodeZenBillingParser.parse(text: "null") == nil)
        #expect(OpenCodeZenBillingParser.parse(text: #"{"customerID":"cus_TEST","balance":100}"#) == nil)
    }
}

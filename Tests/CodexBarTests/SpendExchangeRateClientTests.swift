import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendExchangeRateClientTests {
    @Test
    func `Coinbase response decodes current USD to GBP rate`() throws {
        let data = Data(#"{"data":{"currency":"USD","rates":{"GBP":"0.7527903907"}}}"#.utf8)

        #expect(try SpendExchangeRateClient.decodeUSDToGBP(data) == 0.7527903907)
    }

    @Test
    func `invalid or non USD responses fail closed`() {
        let missingRate = Data(#"{"data":{"currency":"USD","rates":{}}}"#.utf8)
        let wrongBase = Data(#"{"data":{"currency":"EUR","rates":{"GBP":"0.85"}}}"#.utf8)

        #expect(throws: SpendExchangeRateClient.ExchangeRateError.invalidRate) {
            try SpendExchangeRateClient.decodeUSDToGBP(missingRate)
        }
        #expect(throws: SpendExchangeRateClient.ExchangeRateError.invalidRate) {
            try SpendExchangeRateClient.decodeUSDToGBP(wrongBase)
        }
    }

    @Test
    func `successful refresh persists GBP and advances display revision`() async throws {
        let suite = "SpendExchangeRateClientTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        await store.refreshSpendExchangeRate(client: SpendExchangeRateClient(fetchUSDToGBP: { 0.7512 }))

        #expect(defaults.bool(forKey: SpendDisplayCurrencyPreference.displayGBPDefaultsKey))
        #expect(defaults.double(forKey: SpendDisplayCurrencyPreference.usdToGBPRateDefaultsKey) == 0.7512)
        #expect(defaults.object(forKey: SpendDisplayCurrencyPreference.rateUpdatedAtDefaultsKey) is Date)
        #expect(store.spendCurrencyRevision == 1)
    }
}

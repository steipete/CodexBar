import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginCurrencyTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `currency formatting matches Swift including ties and signed zero`(
        engine: ProviderPluginEngineKind) async throws
    {
        for currency in ["USD", "CNY", "EUR", "JPY", "KWD"] {
            for value in [49.585, 49.595, -0.0, 0.0, 1e-7, -1e-7, -49.585, 1234.5] {
                let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
                return { identity: { loginMethod: ctx.format.currency(\(value), '\(currency)') } };
                """)
                let usage = try await runtime.fetchUsage()
                #expect(usage.identity?.loginMethod == UsageFormatter.currencyString(value, currencyCode: currency))
            }
        }
    }
}

import CodexBarCore
import Testing
@testable import CodexBar

struct SpendDashboardTrackedSourceTests {
    @Test
    @MainActor
    func `tracked access includes every saved provider credential without inventing cost coverage`() {
        let settings = testSettingsStore(suiteName: "SpendDashboardTrackedSourceTests-credentials")
        let supportedProviders = UsageProvider.allCases.filter {
            TokenAccountSupportCatalog.support(for: $0) != nil
        }
        for provider in supportedProviders {
            settings.addTokenAccount(provider: provider, label: "\(provider.rawValue) account", token: "fixture")
        }
        settings.addTokenAccount(provider: .openrouter, label: "second account", token: "fixture-2")

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let sources = SpendDashboardSource.trackedSources(settings: settings, store: store)
        let credentialSources = sources.filter { $0.id.contains(":account:") }

        #expect(Set(credentialSources.map(\.provider)) == Set(supportedProviders))
        #expect(credentialSources.count == supportedProviders.count + 1)
        #expect(Set(credentialSources.map(\.id)).count == credentialSources.count)

        let openRouterSources = credentialSources.filter { $0.provider == .openrouter }
        #expect(openRouterSources.count == 2)
        #expect(openRouterSources.allSatisfy { $0.state == .configured })
        #expect(openRouterSources.allSatisfy { !$0.supportsCostHistory })
        #expect(openRouterSources.allSatisfy { !$0.contributesCostHistory })
    }

    @Test
    func `tracked access copy distinguishes missing cost history from zero spend`() {
        let source = SpendDashboardTrackedSource(
            id: "openrouter:account:test",
            provider: .openrouter,
            providerName: "OpenRouter",
            accountName: "Work",
            state: .connected,
            supportsCostHistory: false,
            contributesCostHistory: false)

        #expect(spendDashboardTrackedSourceStatusText(source) == "Usage connected · not in cost total")
    }
}

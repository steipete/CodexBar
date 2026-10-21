import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GeminiWebSourceTests {
    @Test
    func `only explicit web selection uses the Gemini app plugin`() async {
        let descriptor = GeminiProviderDescriptor.descriptor
        #expect(!descriptor.metadata.usesAccountFallback)
        for mode in [ProviderSourceMode.auto, .api] {
            let context = self.context(source: mode)
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
            #expect(strategies.map(\.id) == ["gemini.api"])
            #expect(strategies.first?
                .shouldFallback(on: ProviderPluginError.script("fixture"), context: context) == false)
        }
        let web = await descriptor.fetchPlan.pipeline.resolveStrategies(self.context(source: .web))
        #expect(web.map(\.id) == ["gemini.web"])
        #expect(web.first.map { $0 is ScriptFetchStrategy } == true)
        #expect(descriptor.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
    }

    @Test
    func `source picker clears old quota and web settings stay provider scoped`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "GeminiWebSourceTests")
        let implementation = GeminiProviderImplementation()
        let context = fixture.settingsContext(provider: .gemini)
        let picker = try #require(implementation.settingsPickers(context: context).first {
            $0.id == "gemini-usage-source"
        })
        #expect(picker.binding.wrappedValue == "api")
        #expect(picker.options.map(\.title) == ["Gemini CLI", "Gemini app"])
        fixture.store.snapshots[.gemini] = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
        picker.binding.wrappedValue = "api"
        #expect(fixture.store.snapshots[.gemini] != nil)
        picker.binding.wrappedValue = "web"
        #expect(fixture.store.snapshots[.gemini] == nil)
        #expect(fixture.settings.providerConfig(for: .gemini)?.source == .web)
        #expect(implementation.sourceMode(context: .init(provider: .gemini, settings: fixture.settings)) == .web)

        let field = try #require(implementation.settingsFields(context: context).first)
        #expect(field.isVisible?() == false)
        fixture.settings.geminiCookieSource = .manual
        field.binding.wrappedValue = "SID=fixture-session"
        #expect(field.isVisible?() == true)
        let contribution = try #require(implementation.settingsSnapshot(context: .init(
            settings: fixture.settings, tokenOverride: nil)))
        let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(snapshot[GeminiProviderSettingsKey.self]?.manualCookieHeader == "SID=fixture-session")
        #expect(fixture.settings.providerConfig(for: .claude)?.cookieHeader == nil)

        let presentation = ProviderPresentationContext(
            provider: .gemini,
            settings: fixture.settings,
            store: fixture.store,
            metadata: GeminiProviderDescriptor.descriptor.metadata)
        #expect(implementation.presentation(context: presentation).showsVersionInSettings == false)
        #expect(implementation.presentation(context: presentation).detailLine(presentation) == "Gemini app")
        picker.binding.wrappedValue = "api"
        #expect(field.isVisible?() == false)
        #expect(implementation.presentation(context: presentation).showsVersionInSettings)
    }

    @Test
    func `web widget rows keep app quota labels`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "GeminiWebSourceTests-widget")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 24, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 4, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let rows = fixture.store.widgetUsageRows(provider: .gemini, snapshot: snapshot, now: snapshot.updatedAt)
        #expect(Array(rows.prefix(2)).map(\.title) == ["5-hour", "Weekly"])
    }

    @Test
    func `existing API configuration keeps its source without adding browser selection`() throws {
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"id":"gemini","source":"api"}"#.utf8))
        let roundTrip = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.source == .api)
        #expect(roundTrip.browserID == nil)
        #expect(roundTrip.browserProfileID == nil)
    }

    @Test
    func `percentage picker follows the selected source snapshot labels`() {
        let web = UsageSnapshot(
            primary: .init(usedPercent: 24, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 4, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        #expect(MenuBarPercentWindowPreference.session.label(for: .gemini, snapshot: web) == "5-hour")
        #expect(MenuBarPercentWindowPreference.weekly.label(for: .gemini, snapshot: web) == "Weekly")
        #expect(MenuBarPercentWindowPreference.session.label(for: .gemini) == "Pro")
        #expect(MenuBarPercentWindowPreference.weekly.label(for: .gemini) == "Flash")
    }

    private func context(source: ProviderSourceMode) -> ProviderFetchContext {
        let base = ProviderCutoverTestSupport.context()
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: source,
            includeCredits: false,
            webTimeout: 15,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: base.fetcher,
            claudeFetcher: base.claudeFetcher,
            browserDetection: base.browserDetection)
    }
}

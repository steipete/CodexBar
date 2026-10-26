import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct AbliterationProviderTests {
    @Test
    func `API key uses the standard secure field and configured availability`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "AbliterationProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .abliteration))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .abliteration))
        let field = try #require(fields.first)
        #expect(fields.count == 1)
        #expect(field.kind == .secure)
        #expect(field.title == "API key")
        #expect(ProviderSelection(argument: "ABLITERATION")?.asList == [.abliteration])
        #expect(!implementation.isAvailable(context: .init(
            provider: .abliteration, settings: fixture.settings, environment: [:])))
        field.binding.wrappedValue = "abl_fixture"
        #expect(fixture.settings[providerConfig: .abliteration, field: .apiKey] == "abl_fixture")
        #expect(implementation.isAvailable(context: .init(
            provider: .abliteration, settings: fixture.settings, environment: [:])))
        let descriptor = AbliterationProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["ABLITERATION_API_KEY": "environment-fixture"],
            config: ProviderConfig(id: .abliteration, apiKey: "abl_fixture"))
        #expect(environment["ABLITERATION_API_KEY"] == "abl_fixture")
        #expect(credentials.resolveToken(environment: environment)?.token == "abl_fixture")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.history == .unavailable)
    }

    @Test
    func `credit meter keeps amounts without reset text or monthly pace`() throws {
        let now = Date(timeIntervalSince1970: 1_792_540_800)
        let snapshot = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "$60.00 / $50.00"),
            secondary: nil,
            details: [ProviderDetailSection(title: "Credits", rows: [.init(label: "Balance", value: "$0.00")])],
            updatedAt: now)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .abliteration,
            metadata: #require(ProviderDefaults.metadata[.abliteration]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            paceVisible: true,
            now: now))
        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.title == "Credits")
        #expect(model.metrics.first?.percent == 100)
        #expect(model.metrics.first?.detailText == "$60.00 / $50.00")
        #expect(model.metrics.first?.resetText == nil)
        #expect(model.metrics.first?.pacePercent == nil)
        #expect(model.providerCost == nil)
        #expect(AbliterationProviderDescriptor.descriptor.metadata.usesDetailBackedWindow)

        // The CLI must show the spend summary as detail, never as "Resets $…" (found in the live test).
        let text = CLIRenderer.renderText(
            provider: .abliteration,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "abliteration.ai", status: nil, useColor: false, resetStyle: .countdown),
            now: now)
        #expect(text.contains("$60.00 / $50.00"))
        #expect(!text.contains("Resets $"))
    }

    @Test
    func `diagnostics use app translations before entering the plugin`() {
        configureUsageFormatterLocalizationProvider()
        defer {
            UsageFormatter.clearLocalizationProvider()
            UsageFormatter.clearLocaleProvider()
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("it") {
            #expect(UsageFormatter
                .localized("Check your API key in Settings.") == "Controlla la chiave API nelle Impostazioni.")
            #expect(L("Show abliteration.ai usage", language: "de") == "Nutzung von abliteration.ai anzeigen")
            for message in AbliterationProviderDescriptor.diagnosticMessages {
                #expect(UsageFormatter.localized(message) != message)
            }
        }
    }
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct SonioxProviderTests {
    @Test
    func `standard settings persist the organization key and detect availability`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SonioxProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .soniox))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .soniox))
        let field = try #require(fields.first)
        #expect(fields.count == 1)
        #expect(field.kind == .secure)
        #expect(field.title == "API key")
        #expect(ProviderSelection(argument: "SONIOX")?.asList == [.soniox])
        #expect(!implementation.isAvailable(context: .init(
            provider: .soniox, settings: fixture.settings, environment: [:])))
        field.binding.wrappedValue = "snx_org_fixture"
        #expect(fixture.settings[providerConfig: .soniox, field: .apiKey] == "snx_org_fixture")
        #expect(implementation.isAvailable(context: .init(
            provider: .soniox, settings: fixture.settings, environment: [:])))
    }

    @Test
    func `monthly budget visibility is opt in and survives config round trips`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SonioxVisibilityTests")
        let settings = fixture.settings
        #expect(!settings.isUsageItemVisible(.metric("primary"), for: .soniox))
        #expect(!settings.hasCustomUsageItemVisibility(for: .soniox))
        settings.setUsageItemVisible(true, itemID: .metric("primary"), for: .soniox)
        #expect(settings.isUsageItemVisible(.metric("primary"), for: .soniox))
        #expect(settings.hasCustomUsageItemVisibility(for: .soniox))
        let saved = try CodexBarConfig.decode(from: settings.configSnapshot.encodedData())
        #expect(saved.providerConfig(for: .soniox)?.hiddenUsageItemIDs == [])
        settings.restoreDefaultUsageItemVisibility(for: .soniox)
        #expect(!settings.isUsageItemVisible(.metric("primary"), for: .soniox))
        #expect(!settings.hasCustomUsageItemVisibility(for: .soniox))
        settings.applyExternalConfig(saved, reason: "synthetic-reload", affectsBackgroundWork: false)
        #expect(settings.isUsageItemVisible(.metric("primary"), for: .soniox))
        #expect(settings.hiddenUsageItemIDs(for: .deepgram).isEmpty)
    }

    @Test
    func `menu card defaults to prepaid balance and spend with optional monthly budget`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SonioxMenuCardTests")
        let now = Date(timeIntervalSince1970: 1_792_540_800)
        let resetsAt = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        let snapshot = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 6, windowMinutes: nil, resetsAt: resetsAt, resetDescription: "$6.00 / $100.00"),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 6,
                limit: 100,
                currencyCode: "USD",
                period: "This month",
                resetsAt: resetsAt,
                balance: 18.5,
                updatedAt: now),
            details: [ProviderDetailSection(
                title: "Billing", rows: [.init(label: "Prepaid", value: "USD")])],
            updatedAt: now)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .soniox,
            metadata: #require(ProviderDefaults.metadata[.soniox]),
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
        #expect(model.metrics.first?.title == "Monthly budget")
        #expect(model.metrics.first?.percent == 6)
        #expect(model.metrics.first?.detailText == "$6.00 / $100.00")
        #expect(model.metrics.first?.resetText?.contains("$") == false)
        #expect(model.providerCost?.spendLine == "This month: $6.00")
        #expect(model.providerCost?.balanceLine == "Balance: $18.50")
        // Spend-only cost sections do not display percentage-derived pacing.
        #expect(model.providerCost?.dailyTargetText == nil)

        let visibleModel = model.applyingUsageItemVisibility(
            hiddenItemIDs: fixture.settings.hiddenUsageItemIDs(for: .soniox))
        #expect(visibleModel.metrics.isEmpty)
        #expect(visibleModel.providerCost?.spendLine == "This month: $6.00")
        #expect(visibleModel.providerCost?.balanceLine == "Balance: $18.50")
        #expect(visibleModel.providerCost?.dailyTargetText == nil)
        #expect(model.usageItemDescriptors.contains { $0.id == .metric("primary") && $0.title == "Monthly budget" })
    }

    @Test
    func `billing labels localize while currency stays canonical`() throws {
        let details = try [ProviderDetailSection(title: "Billing", rows: [
            .init(label: "Prepaid", value: "USD"),
            .init(label: "Invoice billing", value: "USD"),
        ])]
        CodexBarLocalizationOverride.$appLanguage.withValue("it") {
            let localized = UsageMenuCardView.Model.localizedProviderDetails(details, provider: .soniox)
            #expect(localized.first?.rows.map(\.label) == ["Prepagato", "Pagamento tramite fattura"])
            #expect(localized.first?.rows.map(\.value) == ["USD", "USD"])
        }
    }
}

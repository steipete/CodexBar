import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorSakanaTests {
    @Test
    func `sakana pay as you go rows render when optional usage is enabled`() throws {
        let lines = try Self.menuLines(showOptionalUsage: true)

        #expect(lines.contains("Balance: $12.34"))
        #expect(lines.contains("Usage: $5.67 · Jun 02, 2026 - Jul 01, 2026"))
    }

    @Test
    func `sakana pay as you go rows are hidden when optional usage is disabled`() throws {
        // Regression for the render-path staleness gap: toggling "Show optional credits and extra
        // usage" off only rebuilds the menu, it does not immediately refetch, so a
        // previously-populated sakanaPayAsYouGo lingers in the cached snapshot. The rows must be
        // gated on the setting, not only on the presence of the (possibly stale) snapshot field.
        let lines = try Self.menuLines(showOptionalUsage: false)

        #expect(!lines.contains(where: { $0.hasPrefix("Balance:") }))
        #expect(!lines.contains(where: { $0.hasPrefix("Usage:") }))
        // The required quota windows must still render regardless of the optional-usage setting.
        #expect(lines.contains(where: { $0.hasPrefix("5-hour") }))
        #expect(lines.contains(where: { $0.hasPrefix("Weekly") }))
    }

    private static func menuLines(showOptionalUsage: Bool) throws -> [String] {
        let suite = "MenuDescriptorSakanaTests-\(showOptionalUsage)"
        let settings = testSettingsStore(suiteName: suite, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = showOptionalUsage

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        try store._setSnapshotForTesting(sakanaMenuSnapshot(now: Date()), provider: .sakana)

        let descriptor = MenuDescriptor.build(
            provider: .sakana,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        return descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
    }
}

struct SakanaMenuCardModelTests {
    @Test
    func `pay as you go renders in the live menu card`() throws {
        let model = try Self.model(showOptionalUsage: true)

        #expect(model.providerDetails.first?.title == "Extra usage")
        #expect(model.providerDetails.first?.rows.first?.value == "$12.34")
        #expect(model.providerDetails.first?.rows.last?.value == "$5.67")
    }

    @Test
    func `pay as you go hides immediately when optional usage is disabled`() throws {
        let model = try Self.model(showOptionalUsage: false)

        #expect(model.providerCost == nil)
        #expect(model.providerDetails.isEmpty)
        #expect(model.metrics.map(\.title) == ["5-hour", "Weekly"])
    }

    private static func model(showOptionalUsage: Bool) throws -> UsageMenuCardView.Model {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = try sakanaMenuSnapshot(now: now)
        let metadata = try #require(ProviderDefaults.metadata[.sakana])

        return UsageMenuCardView.Model.make(.init(
            provider: .sakana,
            metadata: metadata,
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
            showOptionalCreditsAndExtraUsage: showOptionalUsage,
            hidePersonalInfo: false,
            now: now))
    }
}

private func sakanaMenuSnapshot(now: Date) throws -> UsageSnapshot {
    try UsageSnapshot(
        primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
        secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
        tertiary: nil,
        details: [ProviderDetailSection(title: "Extra usage", rows: [
            ProviderDetailSection.Row(label: "Balance", value: "$12.34"),
            ProviderDetailSection.Row(label: "Usage", value: "$5.67", secondaryValue: "Jun 02, 2026 - Jul 01, 2026"),
        ])],
        updatedAt: now,
        identity: ProviderIdentitySnapshot(
            providerID: .sakana, accountEmail: nil, accountOrganization: nil, loginMethod: "Standard $20/mo"))
}

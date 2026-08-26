import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GrokMenuCardModelTests {
    @Test
    func `weekly CLI quota shows projection and pace marker`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == "7% in deficit")
        #expect(metric.detailRightText == "Runs out in 3d")
        #expect(metric.pacePercent != nil)
        #expect(metric.paceOnTop == false)
    }

    @Test
    func `weekly web quota infers projection from reset date`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == "7% in deficit")
        #expect(metric.detailRightText == "Runs out in 3d")
        #expect(metric.pacePercent != nil)
        #expect(metric.paceOnTop == false)
    }

    @Test
    func `weekly web quota beyond default duration does not show projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(8 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `monthly quota does not show weekly projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 30 * 24 * 60,
                resetsAt: now.addingTimeInterval(20 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Monthly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `weekly web quota near reset keeps its label without projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `usage-limit reset coupon uses the shared reset credits block`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let expiresAt = now.addingTimeInterval(2 * 24 * 3600)
        let details = try [
            ProviderDetailSection(
                rows: [
                    ProviderDetailSection.Row(
                        label: "Limit Reset Credits",
                        value: "1 available",
                        secondaryValue: "Expires Sep 12"),
                ]),
        ]
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 29,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            details: details,
            resetCredits: GrokRateLimitResetCreditsSnapshot(
                expirations: [expiresAt],
                updatedAt: now))

        #expect(model.metrics.contains(where: { $0.id == "primary" }))
        #expect(model.limitResetCredits?.text == "1 available")
        #expect(model.limitResetCredits?.expirySummaryText == "2d")
        #expect(model.providerDetails.isEmpty)
    }

    @Test
    func `cached coupon details fall back to the shared reset credits block`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let details = try [
            ProviderDetailSection(
                rows: [
                    ProviderDetailSection.Row(
                        label: "Limit Reset Credits",
                        value: "1 available",
                        secondaryValue: "Expires Sep 12"),
                ]),
        ]
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 29,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            details: details)

        #expect(model.limitResetCredits?.text == "1 available")
        #expect(model.limitResetCredits?.expirySummaryText == "Sep 12")
        #expect(model.providerDetails.isEmpty)
    }

    @Test
    func `expired live coupons do not fall back to cached coupon details`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let details = try [
            ProviderDetailSection(
                rows: [
                    ProviderDetailSection.Row(
                        label: "Limit Reset Credits",
                        value: "1 available",
                        secondaryValue: "Expires Sep 12"),
                ]),
        ]
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 29,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            details: details,
            resetCredits: GrokRateLimitResetCreditsSnapshot(
                expirations: [now.addingTimeInterval(-1)],
                updatedAt: now.addingTimeInterval(-3600)))

        #expect(model.limitResetCredits == nil)
        #expect(model.providerDetails.isEmpty)
    }

    @Test
    func `optional usage disabled hides cached coupon details`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let details = try [
            ProviderDetailSection(
                rows: [
                    ProviderDetailSection.Row(
                        label: "Limit Reset Credits",
                        value: "1 available",
                        secondaryValue: "Expires Sep 12"),
                ]),
        ]
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 29,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            details: details,
            showOptionalUsage: false)

        #expect(model.limitResetCredits == nil)
        #expect(model.providerDetails.isEmpty)
    }

    @Test
    func `weekly web quota near reset keeps its label in the detail menu`() throws {
        let suite = "GrokMenuCardModelTests-detail-menu"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: nil,
                    resetsAt: now.addingTimeInterval(2 * 3600),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: nil),
            provider: .grok)

        let descriptor = MenuDescriptor.build(
            provider: .grok,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains(where: { $0.hasPrefix("Weekly:") }))
        #expect(!lines.contains(where: { $0.hasPrefix("Credits:") }))
    }

    private static func model(
        now: Date,
        window: RateWindow,
        details: [ProviderDetailSection] = [],
        resetCredits: GrokRateLimitResetCreditsSnapshot? = nil,
        showOptionalUsage: Bool = true) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.grok])
        let snapshot = UsageSnapshot(
            primary: window,
            secondary: nil,
            tertiary: nil,
            details: details,
            grokResetCredits: resetCredits,
            updatedAt: now,
            identity: nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .grok,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptionalUsage,
            hidePersonalInfo: false,
            now: now))
    }
}

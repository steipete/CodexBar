import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct SyntheticMenuCardTests {
    private static func makeModel(
        primary: RateWindow?,
        secondary: RateWindow? = nil,
        providerCost: ProviderCostSnapshot? = nil,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let identity = ProviderIdentitySnapshot(
            providerID: .synthetic,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: providerCost,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.synthetic])
        return UsageMenuCardView.Model.make(.init(
            provider: .synthetic,
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }

    @Test
    func `rolling regen text uses parsed tickPercent not hardcoded fallback`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(900),
            resetDescription: nil,
            nextRegenPercent: 2)
        let model = try Self.makeModel(primary: primary, now: now)
        let metric = try #require(model.metrics.first)
        // 50% used / 2% per tick = 25 ticks to full.
        #expect(metric.detailRightText == "Full in ~25 regens")
        #expect(metric.detailLeftText == "52% after next regen")
    }

    @Test
    func `rolling regen omits Synthetic-specific text when tickPercent is missing`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(900),
            resetDescription: nil,
            nextRegenPercent: nil)
        let model = try Self.makeModel(primary: primary, now: now)
        let metric = try #require(model.metrics.first)
        // Without nextRegenPercent we no longer assert a regen-specific label;
        // the renderer must not fabricate ticks-to-full from a guessed rate.
        #expect(metric.detailRightText?.contains("regen") != true)
    }

    @Test
    func `weekly regen text near full reports both labels consistently`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secondary = RateWindow(
            usedPercent: 1,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let cost = ProviderCostSnapshot(
            used: 0.36,
            limit: 36,
            currencyCode: "USD",
            period: "Weekly",
            resetsAt: now.addingTimeInterval(3600),
            nextRegenAmount: 0.72,
            updatedAt: now)
        let model = try Self.makeModel(
            primary: nil,
            secondary: secondary,
            providerCost: cost,
            now: now)
        let weekly = try #require(model.metrics.first(where: { $0.id == "secondary" }))
        // used=$0.36 / nextRegen=$0.72 = 0.5 ticks → between 0.1 and 1.5 → "Full in ~1 regen".
        #expect(weekly.detailRightText == "Full in ~1 regen")
        // remaining 99% + 2% next regen caps at 100% → "100% after next regen".
        #expect(weekly.detailLeftText == "100% after next regen")
    }
}

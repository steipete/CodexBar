import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Regression coverage for #4537: Claude Free accounts return HTTP 200 with `five_hour` and
/// `seven_day` set to null, so the Web usage answer is a successful response that reports no
/// quota window at all. That state must present as "limits unavailable", not as the misleading
/// "No usage yet" placeholder, while spend-only Claude surfaces keep their current presentation.
struct ClaudeEmptyQuotaAvailabilityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `Claude Free web payload with null quota fields yields no rate windows`() throws {
        let payload = Data(#"{"five_hour":null,"seven_day":null}"#.utf8)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(payload)

        #expect(web.sessionPercentUsed == nil)
        #expect(web.weeklyPercentUsed == nil)
        #expect(web.opusPercentUsed == nil)
        #expect(web.extraRateWindows.isEmpty)
        #expect(web.extraUsageCost == nil)
    }

    @Test
    func `quota-less Claude snapshot reports limits unavailable and a clear placeholder`() {
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.now)

        #expect(UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot) == .unavailable)

        let model = Self.model(snapshot: snapshot)
        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == "Limits not available")
    }

    @Test
    func `spend-only Claude snapshot keeps its existing available presentation`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 9.95,
                limit: 150,
                currencyCode: "USD",
                period: "Monthly cap",
                updatedAt: Self.now),
            updatedAt: Self.now)

        #expect(UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot) == .available)
    }

    @Test
    func `measured Claude quota windows remain available`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Self.now)

        #expect(UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot) == .available)
    }

    @Test
    func `synthetic placeholder remains unavailable`() {
        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        let snapshot = UsageSnapshot(primary: placeholder, secondary: nil, updatedAt: Self.now)

        #expect(UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot) == .unavailable)
    }

    @Test
    func `failed Claude fetch without a snapshot keeps limits unjudged`() {
        #expect(UsageLimitsAvailability.resolve(provider: .claude, snapshot: nil) == .available)
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: nil,
            lastErrorDescription: ClaudeStatusProbe.subscriptionQuotaUnavailableDescription) == .unavailable)
    }

    private static func model(snapshot: UsageSnapshot) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            limitsAvailability: UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot),
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: self.now))
    }
}

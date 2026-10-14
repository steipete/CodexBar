import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeSpendWindowTests {
    @Test
    func `spend only account has meter pace and first of month rollover`() throws {
        let data = Data(#"""
        {"five_hour":null,"seven_day":null,
         "extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":2500}}
        """#.utf8)
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .claude)
        #expect(windows.primary?.usedPercent == 25)
        let window = try #require(MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let observedAt = try #require(snapshot.providerCost?.updatedAt)
        let month = try #require(utc.dateInterval(of: .month, for: observedAt))
        let paceWindow = ProviderDescriptorRegistry.descriptor(for: .claude).pace
            .resolvedResetWindowForPace(window)
        #expect(UsagePace.weekly(
            window: paceWindow,
            now: month.start.addingTimeInterval(month.duration / 2),
            defaultWindowMinutes: 0) != nil)
        #expect(window.resetsAt == month.end)
        #expect(windows.primary == window)
        #expect(!IconRenderer.QuotaLayoutPolicy.provider(.claude, snapshot: snapshot).reservesMissingSecondaryLane)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .claude, snapshot: snapshot, supportsAverage: false) == window)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .extraUsage, provider: .claude, snapshot: snapshot, supportsAverage: false) == window)
    }

    @MainActor
    @Test
    func `spend meter renders the same single bar as a single quota provider`() throws {
        let snapshot = Self.snapshot(at: Date())
        let policy = IconRenderer.QuotaLayoutPolicy.provider(.claude, snapshot: snapshot)
        let actual = IconRenderer.makeIcon(
            primaryRemaining: 75,
            weeklyRemaining: nil,
            creditsRemaining: nil,
            stale: false,
            style: .claude,
            hideCritters: true,
            quotaLayoutPolicy: policy)
        let expected = IconRenderer.makeIcon(
            primaryRemaining: 75,
            weeklyRemaining: nil,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            hideCritters: true)
        #expect(try #require(actual.tiffRepresentation) == #require(expected.tiffRepresentation))
    }

    @Test
    func `UTC month rollover and pace follow leap February across the boundary`() throws {
        let before = try #require(ISO8601DateParser.parse("2028-02-29T23:59:59Z"))
        let boundary = try #require(ISO8601DateParser.parse("2028-03-01T00:00:00Z"))
        let february = try #require(Self.snapshot(at: before).claudeMonthlySpendWindow?.window)
        let march = try #require(Self.snapshot(at: boundary).claudeMonthlySpendWindow?.window)
        let capability = ProviderDescriptorRegistry.descriptor(for: .claude).pace
        #expect(february.resetsAt == boundary)
        #expect(march.resetsAt == ISO8601DateParser.parse("2028-04-01T00:00:00Z"))
        #expect(capability.resolvedResetWindowForPace(february).windowMinutes == 29 * 1440)
        #expect(capability.resolvedResetWindowForPace(march).windowMinutes == 31 * 1440)
        let firstHour = UsagePace.weekly(
            window: capability.resolvedResetWindowForPace(march),
            now: boundary.addingTimeInterval(3600),
            defaultWindowMinutes: 0)
        #expect(firstHour != nil)
    }

    @Test
    func `real quota lanes keep their icon and spend cannot become another providers identity`() {
        let quota = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: quota,
            secondary: nil,
            providerCost: Self.snapshot(at: Date()).providerCost,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex, accountEmail: "codex@example.test", accountOrganization: nil, loginMethod: "Pro"))
        #expect(IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .claude).primary == quota)
        #expect(IconRenderer.QuotaLayoutPolicy.provider(.claude, snapshot: snapshot).reservesMissingSecondaryLane)
        #expect(snapshot.accountEmail(for: .claude) == nil)
        #expect(snapshot.loginMethod(for: .claude) == nil)
    }

    private static func snapshot(at date: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25, limit: 100, currencyCode: "USD", period: "Monthly cap", updatedAt: date),
            updatedAt: date)
    }
}

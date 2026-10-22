import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorUnifiedWeeklyPresentationTests {
    @Test
    func `saved pool tokens and primary picker retain the promoted allowance`() throws {
        let usage = try Self.snapshot(used: 20)
        let extras = MenuBarLayoutNamedExtra.windows(provider: .cursor, snapshot: usage)
        #expect(extras.first?.id == "cursor-grok-bot")
        #expect(extras.first?.window.usedPercent == 20)
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: .cursor, snapshot: usage)
        #expect(semantic.session == usage.primary)
        #expect(semantic.weekly == usage.primary)
        #expect(MenuBarPercentWindowPreference.session.label(for: .cursor, snapshot: usage) == "Weekly")
        #expect(MenuBarPercentWindowPreference.weekly.label(for: .cursor, snapshot: usage) == "Weekly")
        let tokens = [MenuBarLayoutToken.extraPercent(id: "cursor-grok-bot")]
        #expect(try MenuBarLayoutRenderExtra.signature(tokens: tokens, provider: .cursor, snapshot: usage) !=
            MenuBarLayoutRenderExtra.signature(tokens: tokens, provider: .cursor, snapshot: Self.snapshot(used: 70)))
    }

    @Test
    func `promoted pool uses weekly notifications and marker thresholds`() throws {
        let settings = testSettingsStore(suiteName: "CursorUnifiedWeeklyPresentationTests")
        settings.quotaWarningNotificationsEnabled = true
        settings.setQuotaWarningThresholds(.weekly, thresholds: [50])
        settings.setQuotaWarningWindowEnabled(.session, enabled: false)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        let notifier = ClaudeExtraWindowQuotaWarningTests.SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing,
            environmentBase: [:])
        defer { store.stopSharedSpendDashboardPublication() }
        try store.handleQuotaWarningTransitions(provider: .cursor, snapshot: Self.snapshot(used: 20))
        let usage = try Self.snapshot(used: 70)
        store.handleQuotaWarningTransitions(provider: .cursor, snapshot: usage)
        #expect(notifier.quotaWarningPosts.count == 1)
        #expect(notifier.quotaWarningPosts.first?.event.window == .weekly)

        let model = try UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: #require(ProviderDefaults.metadata[.cursor]),
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: true,
            quotaWarningThresholds: [.session: [], .weekly: [50]],
            now: Self.now))
        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.warningMarkerPercents == [50])

        let data = store.menuBarLayoutRenderData(
            provider: .cursor,
            snapshot: usage,
            iconKey: "cursor",
            accountLabel: nil,
            costs: .init(today: nil, last30Days: nil, todayUSD: nil, last30DaysUSD: nil),
            now: Self.now)
        let rendered = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[
                .percent(window: .session), .percent(window: .weekly), .lanePercent(lane: .primary),
            ]]),
            data: data,
            icon: nil,
            options: .init(
                size: .regular,
                highContrast: false,
                showUsed: false,
                conditionals: [],
                appearanceName: "aqua",
                isDebugApp: false,
                now: Self.now))
        #expect(rendered.attributedTitle.string == "W 30%\u{2009}W 30%\u{2009}30%")
        #expect(rendered.accessibilityLabel == "Weekly 30%, Weekly 30%, Weekly 30%")
    }

    @Test
    func `compact account rows use the same weekly label as full cards`() throws {
        let usage = try Self.snapshot(used: 70)
        let accounts = (0..<4).map { index in
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "fixture", opaqueID: String(index)),
                provider: .cursor,
                displayLabel: "Account \(index)",
                isActive: index == 0,
                canActivate: false,
                snapshot: usage,
                error: nil,
                sourceLabel: "web")
        }
        let rows = AccountMenuLayoutPlanner.plan(accounts: accounts).rows.compactMap { row in
            if case let .compact(value) = row { return value }
            return nil
        }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.windowDetails.map(\.label) == ["Weekly"] })
    }

    private static let now = Date(timeIntervalSince1970: 1_792_500_000)

    private static func snapshot(used: Double) throws -> UsageSnapshot {
        let reset = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(86400))
        let sand = try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data("""
        {"isUnified":true,"usagePercent":\(used),"hasNonZeroIncludedLimit":true,
         "nextResetTimestampUtc":"\(reset)"}
        """.utf8))
        return CursorStatusSnapshot(
            planPercentUsed: 100,
            planUsedUSD: 10,
            planLimitUSD: 10,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: Self.now.addingTimeInterval(30 * 86400),
            membershipType: "enterprise",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            sandUsage: sand).toUsageSnapshot(now: Self.now)
    }
}

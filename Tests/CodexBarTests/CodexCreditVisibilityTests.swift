import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct CodexCreditVisibilityTests {
    @Test(arguments: [false, true])
    func `widget and menu bar distinguish unavailable credits from confirmed zero`(balanceReadSucceeded: Bool) {
        let credits = Self.credits(balanceReadSucceeded: balanceReadSucceeded)
        let context = CodexConsumerProjection.Context(
            snapshot: Self.snapshot,
            rawUsageError: nil,
            liveCredits: credits,
            rawCreditsError: nil,
            liveDashboard: nil,
            rawDashboardError: nil,
            dashboardAttachmentAuthorized: false,
            dashboardRequiresLogin: false,
            now: Self.now)

        for surface in [CodexConsumerProjection.Surface.widget, .menuBar] {
            let projection = CodexConsumerProjection.make(surface: surface, context: context)
            #expect(projection.credits?.remaining == (balanceReadSucceeded ? 0 : nil))
            #expect(projection.menuBarFallback == .none)
        }
    }

    @Test(arguments: [false, true])
    func `monthly credits remain available when the purchased balance is zero`(balanceReadSucceeded: Bool) {
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Self.now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 100,
                limit: 1000,
                remainingPercent: 90,
                resetsAt: nil,
                updatedAt: Self.now),
            balanceReadSucceeded: balanceReadSucceeded,
            creditsAvailable: true)
        let projection = CodexConsumerProjection.make(
            surface: .menuBar,
            context: CodexConsumerProjection.Context(
                snapshot: nil,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: Self.now))

        #expect(projection.credits?.remaining == 900)
    }

    @Test(arguments: [false, true])
    func `CLI text and cards never print an unread balance as zero`(balanceReadSucceeded: Bool) {
        let credits = Self.credits(balanceReadSucceeded: balanceReadSucceeded)
        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: Self.snapshot,
            credits: credits,
            context: RenderContext(header: "Codex", status: nil, useColor: false, resetStyle: .absolute))
        let cardLines = CLIRenderer.collectCardInfoLines(
            provider: .codex,
            snapshot: Self.snapshot,
            credits: credits,
            notes: [],
            useColor: false,
            now: Self.now)

        #expect(output.contains("Credits: 0 left") == balanceReadSucceeded)
        #expect(cardLines.contains { $0.contains("Credits: 0 left") } == balanceReadSucceeded)
    }

    @Test(arguments: [false, true])
    func `dashboard omits an unread balance and retains a confirmed zero`(balanceReadSucceeded: Bool) throws {
        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "oauth",
            status: nil,
            usage: Self.snapshot,
            credits: Self.credits(balanceReadSucceeded: balanceReadSucceeded),
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let dashboard = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .none,
            generatedAt: Self.now,
            refreshInterval: 60,
            codexBarVersion: nil)

        let provider = try #require(dashboard.providers.first)
        #expect(provider.credits?.remaining == (balanceReadSucceeded ? 0 : nil))
    }

    @Test(arguments: [false, true])
    func `legacy menu distinguishes unavailable credits from confirmed zero`(balanceReadSucceeded: Bool) throws {
        let settings = testSettingsStore(
            suiteName: "CodexCreditVisibilityTests-legacy-menu",
            userDefaults: InMemoryUserDefaults())
        settings.showOptionalCreditsAndExtraUsage = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.credits = Self.credits(balanceReadSucceeded: balanceReadSucceeded)
        var entries: [ProviderMenuEntry] = []
        CodexProviderImplementation().appendUsageMenuEntries(
            context: ProviderMenuUsageContext(
                provider: .codex,
                store: store,
                settings: settings,
                metadata: CodexProviderDescriptor.descriptor.metadata,
                snapshot: Self.snapshot),
            entries: &entries)

        guard case let .text(title, _) = try #require(entries.first) else {
            Issue.record("Expected a credit balance menu entry")
            return
        }
        #expect(title.contains("0 left") == balanceReadSucceeded)
        #expect(title.contains("Unavailable") == !balanceReadSucceeded)
    }

    @Test(arguments: [false, true])
    func `legacy menu honors attached hidden balance and newer workspace recovery`(hasCap: Bool) throws {
        let settings = testSettingsStore(
            suiteName: "CodexCreditVisibilityTests-legacy-attached-balance",
            userDefaults: InMemoryUserDefaults())
        settings.showOptionalCreditsAndExtraUsage = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let old = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: Self.now.addingTimeInterval(-60),
            codexCreditLimit: hasCap ? CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: Self.now.addingTimeInterval(-60)) : nil,
            balanceIsWorkspace: true)
        let previous = CodexExtraUsageCost.attaching(to: Self.snapshot, credits: old)
        let attached = CodexExtraUsageCost.attaching(to: previous, credits: CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Self.now,
            balanceReadSucceeded: false,
            creditsAvailable: true))
        store.credits = old
        let hiddenTitle = try self.legacyMenuTitle(store: store, settings: settings, snapshot: attached)

        #expect(hiddenTitle.contains("Unavailable") == !hasCap)
        #expect(hiddenTitle.contains("100 left") == hasCap)
        #expect(!hiddenTitle.contains("1,234"))
        #expect(store.credits == old)

        for balance in [0.0, 42.0] {
            store.credits = CreditsSnapshot(
                remaining: balance,
                events: [],
                updatedAt: Self.now.addingTimeInterval(60),
                codexCreditLimit: old.codexCreditLimit,
                balanceIsWorkspace: true)
            let title = try self.legacyMenuTitle(store: store, settings: settings, snapshot: attached)
            #expect(title == "Credits: \(Int(balance)) left")
            #expect(!title.contains("Unavailable"))
        }
    }

    private func legacyMenuTitle(
        store: UsageStore,
        settings: SettingsStore,
        snapshot: UsageSnapshot) throws -> String
    {
        var entries: [ProviderMenuEntry] = []
        CodexProviderImplementation().appendUsageMenuEntries(
            context: ProviderMenuUsageContext(
                provider: .codex,
                store: store,
                settings: settings,
                metadata: CodexProviderDescriptor.descriptor.metadata,
                snapshot: snapshot),
            entries: &entries)
        let entry = try #require(entries.first)
        guard case let .text(title, _) = entry else {
            Issue.record("Expected a credit balance menu entry")
            return ""
        }
        return title
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static var snapshot: UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now)
    }

    private static func credits(balanceReadSucceeded: Bool) -> CreditsSnapshot {
        CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now,
            balanceReadSucceeded: balanceReadSucceeded,
            creditsAvailable: true)
    }
}

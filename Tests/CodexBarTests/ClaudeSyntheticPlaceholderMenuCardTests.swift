import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClaudeSyntheticPlaceholderMenuCardTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `synthetic session is unavailable instead of 100 percent remaining`() {
        let model = Self.model(
            snapshot: UsageSnapshot(
                primary: Self.syntheticSession,
                secondary: nil,
                updatedAt: Self.now))

        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == "Limits not available")
        #expect(model.usageNotes.isEmpty)
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: UsageSnapshot(primary: Self.syntheticSession, secondary: nil, updatedAt: Self.now)) ==
            .unavailable)
    }

    @Test
    func `real weekly usage remains visible beside an unavailable session`() {
        let weekly = RateWindow(
            usedPercent: 42,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)
        let model = Self.model(
            snapshot: UsageSnapshot(
                primary: Self.syntheticSession,
                secondary: weekly,
                updatedAt: Self.now))

        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.usageNotes.isEmpty)
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: UsageSnapshot(primary: Self.syntheticSession, secondary: weekly, updatedAt: Self.now)) ==
            .available)
    }

    @Test
    func `real zero usage is not treated as unavailable`() {
        let primary = RateWindow(
            usedPercent: 0,
            windowMinutes: 5 * 60,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)
        let model = Self.model(
            snapshot: UsageSnapshot(primary: primary, secondary: nil, updatedAt: Self.now))

        #expect(model.metrics.map(\.id) == ["primary"])
        #expect(model.usageNotes.isEmpty)
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: UsageSnapshot(primary: primary, secondary: nil, updatedAt: Self.now)) == .available)
    }

    @Test(arguments: [false, true])
    func `only known measured extra quotas establish availability`(known: Bool) {
        let extra = NamedRateWindow(
            id: "claude-weekly-scoped-example",
            title: "Example only",
            window: RateWindow(usedPercent: 6, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            usageKnown: known)
        let snapshot = UsageSnapshot(
            primary: Self.syntheticSession, secondary: nil, extraRateWindows: [extra], updatedAt: Self.now)
        #expect(UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot) ==
            (known ? .available : .unavailable))
    }

    @MainActor
    @Test(arguments: [false, true])
    func `compact overview preserves enterprise spend without quota windows`(showOptional: Bool) throws {
        let model = Self.enterpriseModel(showOptional: showOptional)
        let row = OverviewMenuCardRowView(model: model, storageText: nil, width: 340, layout: .compact)
        #expect(model.metrics.count == (showOptional ? 1 : 0))
        #expect(row.usesFullCard == !showOptional)
        #expect(model.providerCost == nil)
        if showOptional {
            let metric = try #require(model.metrics.first)
            #expect(metric.title == "Extra usage")
            #expect(metric.detailText == "Monthly cap: $9.95 / $150.00")
        }
        #expect(!OverviewMenuCardRowView(model: model, storageText: nil, width: 340).usesFullCard)
    }

    @MainActor
    @Test
    func `render synthetic enterprise overview proof`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_PRESENTATION_PROOF_DIR"] else {
            return
        }
        let hosting = NSHostingView(rootView: OverviewMenuCardRowView(
            model: Self.enterpriseModel(showOptional: true), storageText: nil, width: 340, layout: .compact)
            .padding(16)
            .frame(width: 372)
            .environment(\.locale, Locale(identifier: "en"))
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light))
        hosting.appearance = NSAppearance(named: .aqua)
        let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("enterprise-overview.png"))
    }

    private static func enterpriseModel(showOptional: Bool) -> UsageMenuCardView.Model {
        self.model(snapshot: UsageSnapshot(
            primary: self.syntheticSession,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 9.95, limit: 150, currencyCode: "USD", period: "Monthly cap", updatedAt: self.now),
            updatedAt: self.now), showOptional: showOptional)
    }

    @MainActor
    @Test
    func `render synthetic unavailable quota proof`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_PRESENTATION_PROOF_DIR"] else {
            return
        }
        let model = Self.model(snapshot: UsageSnapshot(
            primary: Self.syntheticSession, secondary: nil, updatedAt: Self.now))
        let hosting = NSHostingView(rootView: UsageMenuCardView(model: model, width: 340)
            .padding(16)
            .frame(width: 372)
            .environment(\.locale, Locale(identifier: "en"))
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light))
        hosting.appearance = NSAppearance(named: .aqua)
        let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("quota.png"))
    }

    private static var syntheticSession: RateWindow {
        RateWindow(
            usedPercent: 0,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
    }

    private static func model(snapshot: UsageSnapshot, showOptional: Bool = true) -> UsageMenuCardView.Model {
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
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: true,
            now: self.now))
    }
}

@MainActor
struct ClaudeSyntheticPlaceholderDisplayTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [false, true])
    func `synthetic session is absent from compact menu and plain CLI output`(withWeekly: Bool) {
        let settings = testSettingsStore(suiteName: "ClaudeSyntheticPlaceholderDisplayTests")
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: withWeekly ? RateWindow(
                usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil) : nil,
            updatedAt: Self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "claude@example.com",
                accountOrganization: nil,
                loginMethod: "web"))
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let descriptor = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let menuLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
        #expect(!menuLines.contains(where: { $0.contains("100% left") }))
        #expect(menuLines.contains("Limits not available") == !withWeekly)
        #expect(menuLines.contains("Weekly: 58% left") == withWeekly)

        let cli = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: Self.now)
        #expect(!cli.contains("100% left"))
        #expect(cli.contains("Limits: not available") == !withWeekly)
        #expect(cli.contains("Weekly: 58% left") == withWeekly)
    }
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct ChutesPresentationTests {
    @Test
    func `menu card keeps quota detail separate from reset text`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.chutes])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .chutes,
            metadata: metadata,
            snapshot: Self.snapshot(now: now),
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

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        #expect(primary.resetText?.hasPrefix("Resets") == true)
        #expect(primary.detailText == "40/100 requests")

        let secondary = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(secondary.resetText == nil)
        #expect(secondary.detailText == "250/1000 credits")
    }

    @Test
    func `CLI keeps quota detail separate from reset text`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = Self.snapshot(now: now)
        let metadata = ProviderDescriptorRegistry.descriptor(for: .chutes).metadata
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .chutes,
            snapshot: snapshot,
            credits: nil,
            source: "api",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: now))

        let primary = try #require(card.metrics.first { $0.label == metadata.sessionLabel })
        #expect(primary.resetText?.hasPrefix("⏳ Resets") == true)
        #expect(primary.detailText == "40/100 requests")

        let secondary = try #require(card.metrics.first { $0.label == metadata.weeklyLabel })
        #expect(secondary.resetText == nil)
        #expect(secondary.detailText == "250/1000 credits")

        let output = CLIRenderer.renderText(
            provider: .chutes,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Chutes",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("40/100 requests"))
        #expect(output.contains("250/1000 credits"))
        #expect(!output.contains("Resets 40/100 requests"))
        #expect(!output.contains("Resets 250/1000 credits"))
    }

    @Test
    func `native menu keeps quota detail separate from reset text`() throws {
        let suite = "ChutesPresentationTests-native-menu"
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
        store._setSnapshotForTesting(Self.snapshot(now: Date()), provider: .chutes)

        let descriptor = MenuDescriptor.build(
            provider: .chutes,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(textLines.contains("40/100 requests"))
        #expect(textLines.contains("250/1000 credits"))
        #expect(textLines.contains { $0.hasPrefix("Resets") })
        #expect(!textLines.contains { $0.contains("Resets 40/100 requests") })
        #expect(!textLines.contains { $0.contains("Resets 250/1000 credits") })
    }

    private static func snapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 240,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: "40/100 requests"),
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "250/1000 credits"),
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .chutes,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }
}

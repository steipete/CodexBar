import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct AbacusQuotaPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(hasReset: Bool) -> UsageSnapshot {
        AbacusUsageSnapshot(
            creditsUsed: hasReset ? 250 : 0,
            creditsTotal: hasReset ? 1000 : 500,
            resetsAt: hasReset ? Self.now.addingTimeInterval(7200) : nil,
            planName: hasReset ? "Pro" : "Basic").toUsageSnapshot()
    }

    private func detail(hasReset: Bool) -> String {
        hasReset ? "250 / 1,000 credits" : "0 / 500 credits"
    }

    @Test(arguments: [false, true])
    func `CLI retains credit totals alongside real billing resets`(hasReset: Bool) throws {
        let snapshot = self.snapshot(hasReset: hasReset)
        let primary = try #require(snapshot.primary)
        let detail = self.detail(hasReset: hasReset)
        #expect(primary.resetDescription == detail)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .abacus,
            snapshot: snapshot,
            credits: nil,
            source: "synthetic",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        let metric = try #require(card.metrics.first)
        #expect(metric.label == "Credits")
        #expect(metric.remainingPercent == (hasReset ? 75 : 100))
        #expect(metric.detailText == detail)
        #expect(metric.resetText == (hasReset ? "⏳ Resets in 2h" : nil))
        #expect(metric.resetAt == primary.resetsAt)
        let text = CLIRenderer.renderText(
            provider: .abacus,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "Abacus AI", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        #expect(text.contains(detail))
        #expect(!text.contains("Resets \(detail)"))
        #expect(text.contains("Resets in 2h") == hasReset)
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_ABACUS_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "abacus-\(hasReset ? "reset" : "balance")"
            let rendered = CLICardsRenderer.render(
                cards: [card], failures: [], terminalWidth: 100, useColor: false)
            try text.write(to: directory.appendingPathComponent("\(name)-text.txt"), atomically: true, encoding: .utf8)
            try rendered.write(
                to: directory.appendingPathComponent("\(name)-cards.txt"), atomically: true, encoding: .utf8)
        }
    }

    @Test(arguments: [false, true])
    func `native quota details billing window and pace stay intact`(hasReset: Bool) throws {
        let snapshot = self.snapshot(hasReset: hasReset)
        let primary = try #require(snapshot.primary)
        let detail = self.detail(hasReset: hasReset)
        let pace = UsagePace.weekly(window: primary, now: Self.now)
        #expect((pace != nil) == hasReset)
        #expect(primary.usedPercent == (hasReset ? 25 : 0))
        #expect((primary.windowMinutes ?? 0) >= 28 * 24 * 60)
        let metadata = try #require(ProviderDefaults.metadata[.abacus])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .abacus,
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
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            weeklyPace: pace,
            now: Self.now))
        let metric = try #require(model.metrics.first)
        #expect(metric.detailText == detail)
        #expect(metric.resetText == (hasReset ? "Resets in 2h" : nil))
        #expect(metric.percent == (hasReset ? 75 : 100))
        #expect((metric.pacePercent != nil) == hasReset)
        #expect(metric.detailIsPaceDerived == hasReset)

        let settings = testSettingsStore(
            suiteName: "AbacusQuotaPresentationTests-\(hasReset)",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(snapshot, provider: .abacus)
        let menu = MenuDescriptor.build(
            provider: .abacus,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = menu.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(value, _) = entry else { return nil }
            return value
        }
        #expect(lines.contains(detail))
        #expect(!lines.contains("Resets \(detail)"))
    }
}

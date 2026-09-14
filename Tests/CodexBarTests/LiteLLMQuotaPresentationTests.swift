import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct LiteLLMQuotaPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let personalDetail = "$403.99 / $900.00"
    private static let teamDetail = "Team Platform: $70.00 / $1,000.00"

    private func snapshot(hasReset: Bool, teamOnly: Bool) -> UsageSnapshot {
        let reset = hasReset ? Self.now.addingTimeInterval(7200) : nil
        return LiteLLMUsageSnapshot(
            userID: teamOnly ? nil : "synthetic-user",
            accountEmail: nil,
            personalSpendUSD: teamOnly ? 0 : 403.99,
            personalBudgetUSD: teamOnly ? nil : 900,
            personalResetAt: teamOnly ? nil : reset,
            teamUsage: .init(
                id: "synthetic-team",
                alias: "Platform",
                spendUSD: 70,
                budgetUSD: 1000,
                resetAt: reset,
                budgetDuration: nil),
            keyName: nil,
            keyExpiresAt: nil,
            updatedAt: Self.now).toUsageSnapshot()
    }

    @Test(arguments: [false, true], [false, true])
    func `CLI text and cards preserve budget amounts separately from resets`(
        hasReset: Bool, teamOnly: Bool) throws
    {
        let snapshot = self.snapshot(hasReset: hasReset, teamOnly: teamOnly)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .litellm,
            snapshot: snapshot,
            credits: nil,
            source: "api",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        let team = try #require(card.metrics.first { $0.label == "Team budget" })
        #expect(team.remainingPercent == 93)
        #expect(team.detailText == Self.teamDetail)
        #expect(team.resetText == (hasReset ? "⏳ Resets in 2h" : nil))
        let personal = card.metrics.first { $0.label == "Personal budget" }
        #expect((personal == nil) == teamOnly)
        if !teamOnly {
            #expect(personal?.detailText == Self.personalDetail)
            #expect(personal?.resetText == (hasReset ? "⏳ Resets in 2h" : nil))
        }

        let text = CLIRenderer.renderText(
            provider: .litellm,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "LiteLLM", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        #expect(text.contains(Self.teamDetail))
        #expect(text.contains(Self.personalDetail) == !teamOnly)
        #expect(!text.contains("Resets $403.99") && !text.contains("Resets Team Platform:"))
        #expect(text.contains("Resets in 2h") == hasReset)

        if let path = ProcessInfo.processInfo.environment["CODEXBAR_LITELLM_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "litellm-\(teamOnly ? "team" : "personal-team")-\(hasReset ? "reset" : "balance")"
            let cards = CLICardsRenderer.render(
                cards: [card], failures: [], terminalWidth: 100, useColor: false)
            try text.write(to: directory.appendingPathComponent("\(name)-text.txt"), atomically: true, encoding: .utf8)
            try cards.write(
                to: directory.appendingPathComponent("\(name)-cards.txt"),
                atomically: true,
                encoding: .utf8)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `native menus preserve personal and team amounts alongside reset dates`(
        hasReset: Bool, teamOnly: Bool) throws
    {
        let snapshot = self.snapshot(hasReset: hasReset, teamOnly: teamOnly)
        let settings = testSettingsStore(
            suiteName: "LiteLLMQuotaPresentationTests-\(hasReset)-\(teamOnly)",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(snapshot, provider: .litellm)
        let menu = MenuDescriptor.build(
            provider: .litellm,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let text = menu.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(value, _) = entry else { return nil }
            return value
        }
        #expect(text.contains(Self.teamDetail))
        #expect(text.contains(Self.personalDetail) == !teamOnly)
        #expect(!text.contains { $0.hasPrefix("Resets $403.99") || $0.hasPrefix("Resets Team Platform:") })
        #expect(text.contains { $0.hasPrefix("Resets ") } == hasReset)

        let metadata = try #require(ProviderDefaults.metadata[.litellm])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .litellm,
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
            now: Self.now))
        let team = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(team.percent == 93)
        #expect(team.detailText == Self.teamDetail)
        #expect(team.resetText == (hasReset ? "Resets in 2h" : nil))
        #expect(model.metrics.contains(where: { $0.id == "primary" }) == !teamOnly)
    }
}

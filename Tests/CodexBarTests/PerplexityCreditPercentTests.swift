import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct PerplexityCreditPercentTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: [false, true])
    func `explicit credit pools render without a duration or fabricated pace`(showUsed: Bool) throws {
        let json = """
        {
          "balance_cents": 3000,
          "renewal_date_ts": \(self.now.addingTimeInterval(7200).timeIntervalSince1970),
          "current_period_purchased_cents": 3000,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 5000 },
            { "type": "promotional", "amount_cents": 4000 }
          ],
          "total_usage_cents": 9000
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: self.now)
            .toUsageSnapshot()
        let text = CLIRenderer.renderText(
            provider: .perplexity,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "Perplexity", status: nil, useColor: false, resetStyle: .countdown),
            now: self.now)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .perplexity,
            snapshot: snapshot,
            credits: nil,
            source: "synthetic",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: self.now))
        for window in [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self) {
            let detail = try #require(window.resetDescription)
            #expect(text.contains(detail))
            #expect(!text.contains("Resets \(detail)"))
            #expect(card.metrics.contains { $0.detailText == detail })
        }
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: .perplexity, snapshot: snapshot)
        #expect(semantic.session == snapshot.primary)
        #expect(semantic.weekly == snapshot.secondary)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == self.now.addingTimeInterval(7200))
        #expect(snapshot.secondary?.resetsAt == nil)
        for window in [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self) {
            #expect(window.windowMinutes == nil)
            #expect(UsagePaceText.sessionPace(provider: .perplexity, window: window, now: self.now) == nil)
        }
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .perplexity, snapshot: snapshot, supportsAverage: false)
        #expect(automatic?.remainingPercent == 75)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .perplexity, snapshot: snapshot, showUsed: showUsed) == (showUsed ? 25 : 75))
        let data = self.renderData(provider: .perplexity, snapshot: snapshot)
        for (preference, expected): (MenuBarPercentWindowPreference, String) in [
            (.session, showUsed ? "C 100%" : "C 0%"),
            (.weekly, showUsed ? "B 25%" : "B 75%"),
            (.automatic, showUsed ? "25%" : "75%"),
        ] {
            let layout = preference.applied(to: MenuBarLayout(lines: [[.percent(window: .automatic)]]))
            let output = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: showUsed,
                    conditionals: [],
                    appearanceName: NSAppearance.Name.aqua.rawValue,
                    isDebugApp: false,
                    now: self.now))
            if let path = ProcessInfo.processInfo.environment["CODEXBAR_PERPLEXITY_PERCENT_PROOF_DIR"] {
                let file = URL(fileURLWithPath: path)
                    .appendingPathComponent("\(preference.rawValue)-\(showUsed ? "used" : "remaining").txt")
                try output.attributedTitle.string.write(to: file, atomically: true, encoding: .utf8)
            }
            #expect(output.attributedTitle.string == expected)
            if preference == .session {
                #expect(output.accessibilityLabel == (showUsed ? "Credits 100%" : "Credits 0%"))
            }
        }
        for token: MenuBarLayoutToken in [
            .resetCountdown, .resetAbsolute,
            .windowResetCountdown(window: .automatic), .windowResetAbsolute(window: .automatic),
            .windowResetCountdown(window: .weekly), .windowResetAbsolute(window: .weekly),
        ] {
            let output = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[token]]),
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: showUsed,
                    conditionals: [],
                    appearanceName: NSAppearance.Name.aqua.rawValue,
                    isDebugApp: false,
                    now: self.now))
            #expect(output.attributedTitle.string == "–")
            #expect(!output.accessibilityLabel.contains("1000/4000"))
        }
    }

    private func renderData(provider: UsageProvider, snapshot: UsageSnapshot) -> MenuBarLayoutRenderData {
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: provider, snapshot: snapshot)
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: provider, snapshot: snapshot, supportsAverage: false)
        return MenuBarLayoutRenderData(
            provider: provider,
            iconKey: provider.rawValue,
            providerName: ProviderDefaults.metadata[provider]?.displayName,
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(snapshot.primary),
            secondary: MenuBarLayoutRenderWindow(snapshot.secondary),
            tertiary: MenuBarLayoutRenderWindow(snapshot.tertiary),
            session: MenuBarLayoutRenderWindow(semantic.session),
            weekly: MenuBarLayoutRenderWindow(semantic.weekly),
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(automatic),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }

    @Test
    func `session labels preserve real duration and reversed window mappings`() {
        for (provider, minutes): (UsageProvider, Int) in [(.codex, 300), (.chutes, 240), (.kimi, 300)] {
            let session = RateWindow(usedPercent: 25, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
            let weekly = RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
            let snapshot = UsageSnapshot(
                primary: provider == .kimi ? weekly : session,
                secondary: provider == .kimi ? session : weekly,
                updatedAt: self.now)
            let output = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
                data: self.renderData(provider: provider, snapshot: snapshot),
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: false,
                    conditionals: [],
                    appearanceName: NSAppearance.Name.aqua.rawValue,
                    isDebugApp: false,
                    now: self.now))
            #expect(output.attributedTitle.string == "\(minutes / 60)h 75%")
            #expect(output.accessibilityLabel == "Session 75%")
        }
    }

    @Test
    func `reset descriptions remain available only when they describe timing`() {
        let date = self.now.addingTimeInterval(7200)
        for provider in [UsageProvider.perplexity, .warp, .codex, .deepseek] {
            for hasDate in [false, true] {
                let description = provider == .deepseek ? "¥2.23" : "tomorrow"
                let window = MenuBarLayoutRenderWindow(RateWindow(
                    usedPercent: 25,
                    windowMinutes: nil,
                    resetsAt: hasDate ? date : nil,
                    resetDescription: description))
                let text = MenuBarLayoutResetText(window: window, provider: provider, now: self.now)
                let fallback: String? = [.codex, .deepseek].contains(provider) ? description : nil
                #expect(text.countdown == (hasDate ? "in 2h" : fallback))
                #expect(text
                    .absolute == (hasDate ? UsageFormatter.resetDescription(from: date, now: self.now) : fallback))
            }
        }
    }

    @Test
    func `automatic preserves credit consumption order with missing or exhausted pools`() {
        let recurring = RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: "recurring")
        let promo = RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "bonus")
        let purchased = RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: "purchased")
        let exhausted = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "exhausted")
        for (primary, secondary, tertiary, expected): (RateWindow?, RateWindow?, RateWindow?, RateWindow?) in [
            (recurring, promo, purchased, recurring),
            (exhausted, promo, purchased, purchased),
            (nil, promo, purchased, purchased),
            (nil, promo, exhausted, promo),
            (exhausted, exhausted, exhausted, exhausted),
            (exhausted, nil, nil, exhausted),
            (nil, nil, nil, nil),
        ] {
            let snapshot = UsageSnapshot(
                primary: primary,
                secondary: secondary,
                tertiary: tertiary,
                updatedAt: self.now)
            #expect(snapshot.automaticPerplexityWindow() == expected)
        }
    }
}

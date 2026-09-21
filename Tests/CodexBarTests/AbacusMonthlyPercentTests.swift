import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AbacusMonthlyPercentTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: [false, true])
    func `explicit monthly credits retain their quota and announce credits`(showUsed: Bool) throws {
        let reset = self.now.addingTimeInterval(7200)
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 250,
            creditsTotal: 1000,
            resetsAt: reset,
            planName: "Pro").toUsageSnapshot()
        let primary = try #require(snapshot.primary)
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: .abacus, snapshot: snapshot)
        #expect(semantic.session == primary)
        #expect(semantic.weekly == nil)
        #expect(primary.usedPercent == 25)
        #expect(primary.resetsAt == reset)
        let start = try #require(Calendar.current.date(byAdding: .month, value: -1, to: reset))
        #expect(primary.windowMinutes == Int(reset.timeIntervalSince(start) / 60))
        #expect(UsagePace.weekly(window: primary, now: self.now) != nil)
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .abacus, snapshot: snapshot, supportsAverage: false)
        #expect(automatic == primary)

        let settings = testSettingsStore(
            suiteName: "AbacusMonthlyPercentTests-\(showUsed)",
            userDefaults: InMemoryUserDefaults())
        let initial = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        let picker = ProviderMenuBarPercentWindowSettingsView(provider: .abacus, settings: settings)
        picker.layoutBinding.wrappedValue = MenuBarPercentWindowPreference.session.applied(to: initial)
        let selected = settings.menuBarLayout(for: .abacus)
        #expect(MenuBarPercentWindowPreference.current(in: selected) == .session)
        let value = showUsed ? "25%" : "75%"
        for preference in [MenuBarPercentWindowPreference.automatic, .session] {
            let output = self.render(
                provider: .abacus,
                snapshot: snapshot,
                layout: preference == .session ? selected : initial,
                showUsed: showUsed)
            if let path = ProcessInfo.processInfo.environment["CODEXBAR_ABACUS_PERCENT_PROOF_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "\(preference.rawValue)-\(showUsed ? "used" : "remaining")"
                try output.attributedTitle.string.write(
                    to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
                try output.accessibilityLabel.write(
                    to: directory.appendingPathComponent("\(name)-accessibility.txt"),
                    atomically: true,
                    encoding: .utf8)
            }
            #expect(output.attributedTitle.string == (preference == .session ? "C \(value)" : value))
            if preference == .session {
                #expect(output.accessibilityLabel == "Credits \(value)")
            }
        }
        let resetOutput = self.render(
            provider: .abacus,
            snapshot: snapshot,
            layout: MenuBarLayout(lines: [[.windowResetCountdown(window: .session)]]),
            showUsed: showUsed)
        #expect(resetOutput.attributedTitle.string == "in 2h")
        #expect(MenuBarPercentWindowPreference.current(in: settings.menuBarLayout(for: .abacus)) == .session)
    }

    @Test
    func `undated unused credits retain the month without inventing reset or pace`() {
        let snapshot = AbacusUsageSnapshot(creditsUsed: 0, creditsTotal: 500, planName: "Basic").toUsageSnapshot()
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: .abacus, snapshot: snapshot)
        #expect(semantic.session == snapshot.primary)
        #expect(semantic.session?.windowMinutes == 30 * 24 * 60)
        #expect(semantic.session?.resetsAt == nil)
        if let window = semantic.session {
            #expect(UsagePace.weekly(window: window, now: self.now) == nil)
        }
        let output = self.render(
            provider: .abacus,
            snapshot: snapshot,
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            showUsed: false)
        #expect(output.attributedTitle.string == "C 100%")
        #expect(output.accessibilityLabel == "Credits 100%")
        let reset = self.render(
            provider: .abacus,
            snapshot: snapshot,
            layout: MenuBarLayout(lines: [[.windowResetCountdown(window: .session)]]),
            showUsed: false)
        #expect(reset.attributedTitle.string == "–")
    }

    @Test
    func `editor and pace accessibility use the same provider window labels`() throws {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 250, creditsTotal: 1000, resetsAt: self.now.addingTimeInterval(7200), planName: "Pro")
            .toUsageSnapshot()
        var proof: [String] = []
        for (token, label): (MenuBarLayoutToken, String) in [
            (.percent(window: .session), "Credits %"),
            (.pace(window: .session), "Credits pace"),
            (.windowResetCountdown(window: .session), "Credits: Resets in"),
            (.windowResetAbsolute(window: .session), "Credits: Reset at"),
        ] {
            let actual = token.editorLabel(provider: .abacus)
            proof.append(actual)
            #expect(actual == label)
            #expect(token.editorAccessibilityLabel(provider: .abacus) == label)
        }
        for pace in [nil, "On track"] {
            let output = self.render(
                provider: .abacus,
                snapshot: snapshot,
                layout: MenuBarLayout(lines: [[.pace(window: .session)]]),
                showUsed: false,
                sessionPace: pace)
            proof.append(output.accessibilityLabel)
            #expect(output.accessibilityLabel == "Credits pace \(pace ?? "unavailable")")
        }
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_ABACUS_PERCENT_PROOF_DIR"] {
            try proof.joined(separator: "\n").write(
                to: URL(fileURLWithPath: path).appendingPathComponent("editor-labels.txt"),
                atomically: true,
                encoding: .utf8)
        }
        for provider in [UsageProvider.codex, .chutes, .kimi] {
            #expect(MenuBarLayoutToken.percent(window: .session).editorLabel(provider: provider) == "Session %")
            #expect(MenuBarLayoutToken.pace(window: .session).editorLabel(provider: provider) == "Session pace")
        }
        #expect(MenuBarLayoutToken.percent(window: .weekly).editorLabel(provider: .perplexity) == "Bonus credits %")
        #expect(MenuBarLayoutToken.pace(window: .weekly).editorLabel(provider: .warp) == "Add-on credits pace")
        #expect(MenuBarConditionalMetric.session.editorLabel(provider: .abacus) == "Credits %")
        #expect(MenuBarConditionalMetric.sessionPace.editorLabel(provider: .abacus) == "Credits pace")
        #expect(MenuBarConditionalMetric.sessionResetsIn.editorLabel(provider: .abacus) == "Credits resets in")
        #expect(MenuBarConditionalMetric.weekly.editorLabel(provider: .perplexity) == "Bonus credits %")
        #expect(MenuBarConditionalMetric.weeklyResetsIn.editorLabel(provider: .warp) == "Add-on credits resets in")
    }

    @Test
    func `real four and five hour session labels remain duration based`() {
        for (provider, minutes): (UsageProvider, Int) in [(.chutes, 240), (.codex, 300)] {
            let snapshot = UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: minutes, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.now)
            let output = self.render(
                provider: provider,
                snapshot: snapshot,
                layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
                showUsed: false)
            #expect(output.attributedTitle.string == "\(minutes / 60)h 75%")
            #expect(output.accessibilityLabel == "Session 75%")
        }
        let missing = MenuBarLayoutSemanticWindowResolver.windows(provider: .abacus, snapshot: nil)
        #expect(missing.session == nil)
        #expect(missing.weekly == nil)
    }

    private func render(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        layout: MenuBarLayout,
        showUsed: Bool,
        sessionPace: String? = nil) -> MenuBarLayoutRenderedTitle
    {
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: provider, snapshot: snapshot)
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: provider, snapshot: snapshot, supportsAverage: false)
        let data = MenuBarLayoutRenderData(
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
            sessionPace: sessionPace,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        return MenuBarLayoutRenderer().render(
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
    }
}

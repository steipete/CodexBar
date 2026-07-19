import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeCLIScopedWeeklyUsageTests {
    @Test
    func `CLI usage surfaces Fable scoped weekly limit`() async throws {
        let cliUsage = """
        Settings  Status  Config  Usage  Stats

        Current session
        9% used
        Resets 2:09pm (Europe/Prague)

        Current week (all models)
        67% used
        Resets Jul 10 t 2:59am (Europe/Prague)

        Current week (Fable)
        68% used
        Reset Jul 10 at 2:59am (Europe/Prague)

        Current week (Example Model)
        12% used
        """
        let status = try ClaudeStatusProbe.parse(text: cliUsage)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in status }

        let snapshot = try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                try await fetcher.loadLatestUsage(model: "sonnet")
            }
        }

        let fable = try #require(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.title == "Fable only")
        #expect(fable.window.usedPercent == 68)
        #expect(fable.window.resetDescription == "Reset Jul 10 at 2:59am (Europe/Prague)")
        let example = try #require(
            snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-example-model" })
        #expect(example.title == "Example Model only")
        #expect(example.window.usedPercent == 12)
        #expect(example.window.resetDescription == "Resets Jul 10 at 2:59am (Europe/Prague)")
        #expect(snapshot.opus == nil)
    }

    @Test
    func `scoped weekly panel does not become all models weekly usage`() throws {
        let cliUsage = """
        Current session
        9% used

        Current week (Fable)
        68% used
        """

        let snapshot = try ClaudeStatusProbe.parse(text: cliUsage)

        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.secondaryResetDescription == nil)
        #expect(snapshot.extraRateWindows.map(\.title) == ["Fable only"])
    }

    @Test
    func `compact scoped weekly label is parsed`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Current session
        9% used

        Currentweek(Fable)
        68% used
        """)

        #expect(snapshot.extraRateWindows.map(\.title) == ["Fable only"])
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 68)
    }

    @Test
    func `overlapping scoped model names do not cross panel boundaries`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Current session
        9% used

        Current week (Example Model)
        rendering

        Current week (Example Model Plus)
        42% used
        """)

        #expect(snapshot.extraRateWindows.map(\.title) == ["Example Model Plus only"])
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 42)
    }

    @Test
    func `informational Sonnet prose does not duplicate a scoped limit`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Current session
        9% used

        Current week (all models)
        20% used

        Current week (Fable)
        42% used

        Sonnet now has its own limit.
        """)

        #expect(snapshot.opusPercentLeft == nil)
        #expect(snapshot.extraRateWindows.map(\.title) == ["Fable only"])
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 42)
    }

    @Test
    func `Sonnet prefixed scoped model does not become legacy quota`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Current session
        9% used

        Current week (all models)
        20% used

        Current week (Sonnet Test Variant)
        42% used
        """)

        #expect(snapshot.opusPercentLeft == nil)
        #expect(snapshot.extraRateWindows.map(\.title) == ["Sonnet Test Variant only"])
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 42)
    }

    @Test
    func `later complete scoped panel replaces partial redraw`() throws {
        let spacer = Array(repeating: "rendering", count: 14).joined(separator: "\n")
        let cliUsage = """
        Current session
        9% used

        Current week (all models)
        67% used

        Current week (Fable)
        \(spacer)

        Current week (Fable)
        70% used
        Reset Jul 10 at 2:59am (Europe/Prague)
        """

        let snapshot = try ClaudeStatusProbe.parse(text: cliUsage)
        let fable = try #require(snapshot.extraRateWindows.first)

        #expect(snapshot.extraRateWindows.count == 1)
        #expect(fable.window.usedPercent == 70)
        #expect(fable.window.resetDescription == "Reset Jul 10 at 2:59am (Europe/Prague)")
    }

    @Test
    func `incomplete scoped panel stops at session redraw`() throws {
        let cliUsage = """
        Current week (Fable)
        rendering

        Current session
        9% used

        Current week (all models)
        20% used
        """

        let snapshot = try ClaudeStatusProbe.parse(text: cliUsage)

        #expect(snapshot.sessionPercentLeft == 91)
        #expect(snapshot.weeklyPercentLeft == 80)
        #expect(snapshot.extraRateWindows.isEmpty)
    }

    @Test
    func `incomplete all models panel does not consume scoped percentage`() throws {
        let cliUsage = """
        Current session
        9% used

        Current week (all models)
        rendering

        Current week (Fable)
        42% used
        """

        let snapshot = try ClaudeStatusProbe.parse(text: cliUsage)

        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.extraRateWindows.map(\.title) == ["Fable only"])
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 42)
    }

    @Test
    func `incomplete Opus panel does not consume prefixed scoped percentage`() throws {
        let cliUsage = """
        Current session
        9% used

        Current week (all models)
        20% used

        Current week (Opus)
        rendering

        Current week (Opus Test Variant)
        42% used
        """

        let snapshot = try ClaudeStatusProbe.parse(text: cliUsage)

        #expect(snapshot.opusPercentLeft == nil)
        #expect(snapshot.extraRateWindows.map(\.title) == ["Opus Test Variant only"])
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 42)
    }

    @Test
    func `later complete scoped panel replaces earlier complete value`() throws {
        let cliUsage = """
        Current session
        9% used

        Current week (all models)
        67% used

        Current week (Fable)
        20% used

        Current week (Fable)
        70% used
        """

        let snapshot = try ClaudeStatusProbe.parse(text: cliUsage)
        let fable = try #require(snapshot.extraRateWindows.first)

        #expect(snapshot.extraRateWindows.count == 1)
        #expect(fable.window.usedPercent == 70)
    }

    @Test
    func `web extra windows merge with CLI scoped weekly limits`() throws {
        let fable = NamedRateWindow(
            id: "claude-weekly-scoped-fable",
            title: "Fable only",
            window: RateWindow(
                usedPercent: 68,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Resets Jul 10 at 2:59am (Europe/Prague)"))
        let webFable = try #require(ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: [
            ClaudeScopedWeeklyLimitMapper.Limit(
                kind: "weekly_scoped",
                group: "weekly",
                percent: 70,
                resetsAt: nil,
                modelID: "test-only-fable-id",
                modelName: "Fable"),
        ]).first)
        let routines = NamedRateWindow(
            id: "claude-routines",
            title: "Daily Routines",
            window: RateWindow(
                usedPercent: 11,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil))

        let merged = ClaudeUsageFetcher._mergeExtraRateWindowsForTesting(
            primary: [fable],
            web: [webFable, routines])

        #expect(merged.map(\.id) == ["claude-weekly-scoped-fable", "claude-routines"])
        #expect(webFable.id == "claude-weekly-scoped-test-only-fable-id")
        #expect(merged.first?.window.usedPercent == 68)
        #expect(merged.last?.title == "Daily Routines")
    }

    @Test
    func `same title web limits keep distinct stable IDs`() {
        let webLimits = ["first-id", "second-id"].map { id in
            NamedRateWindow(
                id: "claude-weekly-scoped-\(id)",
                title: "Example Model only",
                window: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil))
        }

        let merged = ClaudeUsageFetcher._mergeExtraRateWindowsForTesting(
            primary: [],
            web: webLimits)

        #expect(merged.map(\.id) == [
            "claude-weekly-scoped-first-id",
            "claude-weekly-scoped-second-id",
        ])
    }

    @Test
    func `ambiguous same title web limits survive CLI merge`() {
        let cli = NamedRateWindow(
            id: "claude-weekly-scoped-example-model",
            title: "Example Model only",
            window: RateWindow(
                usedPercent: 20,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil))
        let webLimits = ["first-id", "second-id"].map { id in
            NamedRateWindow(
                id: "claude-weekly-scoped-\(id)",
                title: "Example Model only",
                window: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil))
        }

        let merged = ClaudeUsageFetcher._mergeExtraRateWindowsForTesting(
            primary: [cli],
            web: webLimits)

        #expect(merged.map(\.id) == [
            "claude-weekly-scoped-example-model",
            "claude-weekly-scoped-first-id",
            "claude-weekly-scoped-second-id",
        ])
    }
}

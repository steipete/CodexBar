import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICardsRendererTests {
    @Test
    func `computes column count from terminal width`() {
        #expect(CLICardsRenderer.columnCount(terminalWidth: 80) == 2)
        #expect(CLICardsRenderer.columnCount(terminalWidth: 120) == 3)
        #expect(CLICardsRenderer.columnCount(terminalWidth: 160) == 4)
        #expect(CLICardsRenderer.columnCount(terminalWidth: 30) == 1)
    }

    @Test
    func `renders single codex card without color`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: .init(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: "Fri at 9:00 AM"),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: CreditsSnapshot(remaining: 42, events: [], updatedAt: Date()),
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: Date()))

        let output = CLICardsRenderer.render(cards: [card], failures: [], terminalWidth: 80, useColor: false)

        #expect(output.contains("Codex"))
        #expect(output.contains("[oauth]"))
        #expect(output.contains("PLAN Pro 20x"))
        #expect(output.contains("Session"))
        #expect(output.contains("88% left"))
        #expect(output.contains("[ "))
        #expect(output.contains("━"))
        #expect(output.contains("Credits:"))
        #expect(output.contains("42 left"))
        #expect(output.contains("@ user@example.com"))
        #expect(output.contains("╰"))
    }

    @Test
    func `card includes account line`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            source: "cli",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: Date()))

        let lines = CLICardsRenderer.renderCard(card, width: 48, useColor: false)
        let joined = lines.joined(separator: "\n")

        #expect(joined.contains("@ user@example.com"))
        #expect(joined.contains("Session"))
        #expect(!joined.contains("Plan: Pro 20x"))
    }

    @Test
    func `renders two card grid at fixed width`() {
        let codex = CLICardModel(
            provider: .codex,
            title: "Codex",
            sourceLabel: "oauth",
            planBadge: "Pro",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 88, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let claude = CLICardModel(
            provider: .claude,
            title: "Claude",
            sourceLabel: "web",
            planBadge: "Max",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 50, resetText: nil)],
            extraLines: [],
            statusLine: nil)

        let output = CLICardsRenderer.render(cards: [codex, claude], failures: [], terminalWidth: 120, useColor: false)

        #expect(output.contains("Codex"))
        #expect(output.contains("Claude"))
        #expect(output.contains("88% left"))
        #expect(output.contains("50% left"))
        #expect(output.components(separatedBy: "╰").count >= 3)
    }

    @Test
    func `renders failure footer without cards`() {
        let failures = [
            CLICardFailure(provider: .cursor, accountLabel: nil, message: "not configured"),
        ]
        let output = CLICardsRenderer.render(cards: [], failures: failures, terminalWidth: 80, useColor: false)

        #expect(output.contains("Failed providers:"))
        #expect(output.contains("Cursor: not configured"))
    }

    @Test
    func `appends failure footer after successful cards`() {
        let card = CLICardModel(
            provider: .codex,
            title: "Codex",
            sourceLabel: "oauth",
            planBadge: nil,
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 88, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let failures = [
            CLICardFailure(provider: .grok, accountLabel: nil, message: "timeout"),
        ]

        let output = CLICardsRenderer.render(cards: [card], failures: failures, terminalWidth: 80, useColor: false)

        #expect(output.contains("88% left"))
        #expect(output.contains("Failed providers:"))
        #expect(output.contains("Grok: timeout"))
    }

    @Test
    func `brief mode renders usage table`() {
        let card = CLICardModel(
            provider: .claude,
            title: "Claude",
            sourceLabel: "web",
            planBadge: "Max",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 2, resetText: "⏳ Resets in 1h 49m")],
            extraLines: [],
            statusLine: nil)
        let rows = CLICardsBriefRenderer.makeRows(cards: [card])
        let output = CLICardsBriefRenderer.render(
            rows: rows,
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(output.contains("codexbar • AI Usage & Limits"))
        #expect(output.contains("Provider"))
        #expect(output.contains("Claude"))
        #expect(output.contains("web"))
        #expect(output.contains("Max"))
        #expect(output.contains("98%"))
        #expect(output.contains("█"))
        #expect(output.contains("1h 49m"))
        #expect(output.contains("⚠ Warnings:"))
        let tableLine = output.split(separator: "\n").first { $0.hasPrefix("┌") } ?? ""
        #expect(tableLine.count >= 50)
        #expect(tableLine.count <= 72)
    }

    @Test
    func `enhanced brief mode fills bars from used percentage`() {
        let rows = CLICardsBriefRenderer.makeRows(cards: [
            CLICardModel(
                provider: .codex,
                title: "Unused",
                sourceLabel: "oauth",
                planBadge: nil,
                accountLine: nil,
                infoLines: [],
                metrics: [CLICardMetric(label: "Session", remainingPercent: 100, resetText: nil)],
                extraLines: [],
                statusLine: nil),
            CLICardModel(
                provider: .openrouter,
                title: "Exhausted",
                sourceLabel: "api",
                planBadge: nil,
                accountLine: nil,
                infoLines: [],
                metrics: [CLICardMetric(label: "Session", remainingPercent: 0, resetText: nil)],
                extraLines: [],
                statusLine: nil),
        ])
        let output = CLICardsBriefRenderer.render(
            rows: rows,
            failures: [],
            terminalWidth: 80,
            useColor: true,
            enhanced: true,
            now: Date(timeIntervalSince1970: 0))
        let plainLines = TextParsing.stripANSICodes(output).split(separator: "\n")
        let unusedLine = String(plainLines.first { $0.contains("Unused") } ?? "")
        let exhaustedLine = String(plainLines.first { $0.contains("Exhausted") } ?? "")

        #expect(unusedLine.contains("0%"))
        #expect(unusedLine.filter { $0 == "█" }.isEmpty)
        #expect(exhaustedLine.contains("100%"))
        #expect(exhaustedLine.filter { $0 == "░" }.isEmpty)
    }

    @Test
    func `enhanced mode uses truecolor gradient bars`() {
        let card = CLICardModel(
            provider: .codex,
            title: "Codex",
            sourceLabel: "oauth",
            planBadge: "Pro",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 50, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let output = CLICardsRenderer.render(
            cards: [card],
            failures: [],
            terminalWidth: 80,
            useColor: true,
            enhanced: true)
        #expect(output.contains("38;2;"))
        #expect(output.contains("48;2;"))
        #expect(output.contains("[ "))
    }
}

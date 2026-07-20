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
    func `synthetic quota lanes do not replace real brief usage`() {
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: .init(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Date(timeIntervalSince1970: 0)))
        let rows = CLICardsBriefRenderer.makeRows(cards: [card])

        #expect(card.metrics.map(\.label) == ["Weekly"])
        #expect(rows.first?.usedPercent == 20)
    }

    @Test
    func `brief reset summary wraps to terminal width`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let card = CLICardModel(
            provider: .alibabatokenplan,
            title: "Alibaba Token Plan",
            sourceLabel: "web",
            planBadge: "International",
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(
                label: "Monthly budget",
                remainingPercent: 50,
                resetText: "⏳ Resets July 30 at 11:59 PM",
                resetAt: now.addingTimeInterval(3600))],
            extraLines: [],
            statusLine: nil)

        let output = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 40,
            useColor: false,
            now: now)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(output.contains("Next reset: Alibaba Token Plan"))
        #expect(lines.allSatisfy { $0.count <= 40 })
    }

    @Test
    func `detail backed quota descriptions are not rendered as resets`() {
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "25/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .kilo,
            snapshot: snapshot,
            credits: nil,
            source: "api",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Date(timeIntervalSince1970: 0)))

        #expect(card.metrics.first?.resetText == nil)
        #expect(card.metrics.first?.detailText == "25/100 credits")

        let output = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))
        #expect(!output.contains("Next reset"))
        #expect(!output.contains("Reset 25/100 credits"))
    }

    @Test
    func `card metrics honor reset display style`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)
        let countdown = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: now))
        let absolute = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            source: "oauth",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: now))

        #expect(countdown.metrics.first?.resetText != absolute.metrics.first?.resetText)
        #expect(countdown.metrics.first?.resetText?.contains("in 1h") == true)
        #expect(absolute.metrics.first?.resetAt == now.addingTimeInterval(3600))
    }

    @Test
    func `long detail rows stay within card width`() {
        let card = CLICardModel(
            provider: .clawrouter,
            title: "ClawRouter",
            sourceLabel: "api",
            planBadge: nil,
            accountLine: nil,
            infoLines: ["Workspace: " + String(repeating: "long-name-", count: 12)],
            metrics: [],
            extraLines: [],
            statusLine: nil)

        let lines = CLICardsRenderer.renderCard(card, width: 38, useColor: true, enhanced: true)
        #expect(lines.allSatisfy { TextParsing.stripANSICodes($0).count == 38 })
    }

    @Test
    func `brief warnings name the actual quota metric`() {
        let card = CLICardModel(
            provider: .openrouter,
            title: "OpenRouter",
            sourceLabel: "api",
            planBadge: nil,
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Spend", remainingPercent: 10, resetText: nil)],
            extraLines: [],
            statusLine: nil)

        let output = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(output.contains("OpenRouter Spend: 90% used"))
        #expect(!output.contains("session limit"))
    }

    @Test
    func `brief rows preserve account identity`() {
        let cards = [
            CLICardModel(
                provider: .codex,
                title: "Codex",
                sourceLabel: "oauth",
                planBadge: "Pro",
                accountLine: "one@x.dev",
                infoLines: [],
                metrics: [CLICardMetric(label: "Session", remainingPercent: 80, resetText: nil)],
                extraLines: [],
                statusLine: nil),
            CLICardModel(
                provider: .codex,
                title: "Codex",
                sourceLabel: "oauth",
                planBadge: "Pro",
                accountLine: "two@x.dev",
                infoLines: [],
                metrics: [CLICardMetric(label: "Session", remainingPercent: 60, resetText: nil)],
                extraLines: [],
                statusLine: nil),
        ]

        let output = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: cards),
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(output.contains("one@x.dev"))
        #expect(output.contains("two@x.dev"))
    }

    @Test
    func `brief warnings wrap to terminal width`() {
        let cards = ["OpenRouter", "Antigravity", "CommandCode"].map { title in
            CLICardModel(
                provider: .openrouter,
                title: title,
                sourceLabel: "api",
                planBadge: nil,
                accountLine: nil,
                infoLines: [],
                metrics: [CLICardMetric(label: "Monthly budget", remainingPercent: 5, resetText: nil)],
                extraLines: [],
                statusLine: nil)
        }

        let output = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: cards),
            failures: [],
            terminalWidth: 40,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))
        let warningLines = output.split(separator: "\n").filter {
            $0.contains("Warnings:") || $0.contains("% used")
        }

        #expect(warningLines.count > 1)
        #expect(warningLines.allSatisfy { $0.count <= 40 })
    }

    @Test
    func `brief summary ignores unparseable reset labels and fits narrow terminals`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = CLICardsBriefRenderer.makeRows(cards: [
            CLICardModel(
                provider: .kilo,
                title: "Kilo",
                sourceLabel: "api",
                planBadge: nil,
                accountLine: nil,
                infoLines: [],
                metrics: [CLICardMetric(label: "Credits", remainingPercent: 75, resetText: "Reset Unlimited")],
                extraLines: [],
                statusLine: nil),
            CLICardModel(
                provider: .codex,
                title: "Codex",
                sourceLabel: "oauth",
                planBadge: "Pro",
                accountLine: nil,
                infoLines: [],
                metrics: [CLICardMetric(
                    label: "Session",
                    remainingPercent: 50,
                    resetText: "⏳ Resets in 5h",
                    resetAt: now.addingTimeInterval(5 * 3600))],
                extraLines: [],
                statusLine: nil),
        ])

        let output = CLICardsBriefRenderer.render(
            rows: rows,
            failures: [],
            terminalWidth: 40,
            useColor: false,
            now: now)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(output.contains("Next reset: Codex in 5h"))
        #expect(!output.contains("Next reset: Kilo"))
        #expect(lines.allSatisfy { $0.count <= 40 })
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
    func `standard brief mode fills bars from used percentage`() {
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
            useColor: false,
            enhanced: false,
            now: Date(timeIntervalSince1970: 0))
        let plainLines = output.split(separator: "\n")
        let unusedLine = String(plainLines.first { $0.contains("Unused") } ?? "")
        let exhaustedLine = String(plainLines.first { $0.contains("Exhausted") } ?? "")

        #expect(unusedLine.contains("0%"))
        #expect(unusedLine.filter { $0 == "█" }.isEmpty)
        #expect(exhaustedLine.contains("100%"))
        #expect(exhaustedLine.filter { $0 == "░" }.isEmpty)
    }

    @Test
    func `standard card grid shows empty remaining bar at exhaustion`() {
        let card = CLICardModel(
            provider: .openrouter,
            title: "Exhausted",
            sourceLabel: "api",
            planBadge: nil,
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 0, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let lines = CLICardsRenderer.renderCard(card, width: 48, useColor: false, enhanced: false)
        let barLine = String(lines.first { $0.contains("[ ") && $0.contains("]") } ?? "")
        #expect(barLine.filter { $0 == "━" }.isEmpty)
    }

    @Test
    func `enhanced card grid shows empty remaining bar at exhaustion`() {
        let card = CLICardModel(
            provider: .openrouter,
            title: "Exhausted",
            sourceLabel: "api",
            planBadge: nil,
            accountLine: nil,
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 0, resetText: nil)],
            extraLines: [],
            statusLine: nil)
        let lines = CLICardsRenderer.renderCard(card, width: 48, useColor: true, enhanced: true)
        let plainBarLine = TextParsing.stripANSICodes(
            String(lines.first { $0.contains("[ ") && $0.contains("]") } ?? ""))
        #expect(plainBarLine.filter { !$0.isWhitespace && $0 != "│" && $0 != "[" && $0 != "]" }.isEmpty)
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

    @Test
    func `claude swap active account renders without inferred plan`() {
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "active@example.com",
                accountOrganization: nil,
                loginMethod: "claude-swap"))
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"),
            provider: .claude,
            displayLabel: "active@example.com",
            isActive: true,
            snapshot: snapshot,
            error: nil,
            sourceLabel: "claude-swap")
        let card = CLICardsRenderer.makeClaudeSwapCard(
            account: account,
            renderOptions: CLIClaudeSwapCardsRenderOptions(
                status: nil,
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: nil,
                now: Date(timeIntervalSince1970: 0)))
        let full = CLICardsRenderer.renderCard(card, width: 38, useColor: false).joined(separator: "\n")
        let brief = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 40,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))

        #expect(card.planBadge == nil)
        #expect(full.contains("@ active@example.com [active]"))
        #expect(!full.contains("PLAN Claude-Swap"))
        #expect(brief.contains("[active]"))
        #expect(!brief.contains("Claude-Swap"))
        #expect(full.split(separator: "\n").allSatisfy { $0.count == 38 })
        #expect(brief.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { $0.count <= 40 })
    }

    @Test
    func `claude swap sentinel text survives full and brief projections`() {
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "7"),
            provider: .claude,
            displayLabel: "bad\u{1B}[31m\r\n" + String(repeating: "x", count: 300),
            isActive: true,
            snapshot: nil,
            error: "API-key account; subscription usage is unavailable.",
            sourceLabel: "claude-swap")
        let card = CLICardsRenderer.makeClaudeSwapCard(
            account: account,
            renderOptions: CLIClaudeSwapCardsRenderOptions(
                status: nil,
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: nil,
                now: Date(timeIntervalSince1970: 0)))
        let full = CLICardsRenderer.renderCard(card, width: 42, useColor: false).joined(separator: "\n")
        let brief = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [card]),
            failures: [],
            terminalWidth: 80,
            useColor: false,
            now: Date(timeIntervalSince1970: 0))
        let briefRow = brief.split(separator: "\n").first { $0.contains("API-key") } ?? ""

        #expect(card.accountLine?.unicodeScalars.count == CLIClaudeSwapText.labelScalarLimit)
        #expect(card.accountLine?.contains("\u{1B}") == false)
        #expect(card.accountLine?.contains("\n") == false)
        #expect(card.isActive)
        #expect(full.contains("[active]"))
        #expect(full.contains("API-key account;"))
        #expect(full.contains("subscription usage"))
        #expect(full.contains("unavailable."))
        #expect(brief.contains("Claude [active]"))
        #expect(brief.contains("API-key account"))
        #expect(briefRow.hasSuffix(" — │"))
        #expect(card.metrics.isEmpty)
    }
}

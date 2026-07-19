import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICardsClaudeSwapTests {
    private actor InvocationCounter {
        private(set) var value = 0

        func increment() {
            self.value += 1
        }
    }

    private struct AdapterError: LocalizedError, Sendable {
        let text: String
        var errorDescription: String? {
            self.text
        }
    }

    private func ambientOutput(failed: Bool = false) -> UsageCommandOutput {
        var output = UsageCommandOutput()
        output.cards = [CLICardModel(
            provider: .claude,
            title: "Ambient Claude",
            sourceLabel: "oauth",
            planBadge: "Max",
            accountLine: "ambient@example.com",
            infoLines: [],
            metrics: [CLICardMetric(label: "Session", remainingPercent: 50, resetText: nil)],
            extraLines: [],
            statusLine: nil)]
        if failed {
            output.cardFailures = [CLICardFailure(provider: .claude, accountLabel: nil, message: "ambient failed")]
            output.exitCode = .failure
        }
        return output
    }

    private func renderOptions(status: ProviderStatusPayload? = nil) -> CLIClaudeSwapCardsRenderOptions {
        CLIClaudeSwapCardsRenderOptions(
            status: status,
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func row(
        number: Int,
        active: Bool = false,
        status: ClaudeSwapUsageStatus = .ok,
        email: String? = nil,
        hasUsage: Bool = true) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email ?? "account-\(number)@example.com",
            isActive: active,
            usageStatus: status,
            fiveHour: hasUsage ? ClaudeSwapUsageWindow(usedPercent: Double(number * 10), resetsAt: nil) : nil,
            sevenDay: nil)
    }

    @Test
    func `configured executable path strips surrounding quotes`() {
        for rawPath in ["  \"/tmp/cswap\"  ", "  '/tmp/cswap'  "] {
            let config = ProviderConfig(id: .claude, claudeSwapExecutablePath: rawPath)
            #expect(CLIClaudeSwapCards.executablePath(from: config) == "/tmp/cswap")
        }
        #expect(CLIClaudeSwapCards.executablePath(from: nil).isEmpty)
    }

    @Test
    func `single account config is backward compatible and round trips opt in`() throws {
        let legacyData = Data(#"{"id":"claude"}"#.utf8)
        let legacy = try JSONDecoder().decode(ProviderConfig.self, from: legacyData)
        #expect(legacy.claudeSwapShowSingleAccount != true)

        let enabled = ProviderConfig(id: .claude, claudeSwapShowSingleAccount: true)
        let encoded = try JSONEncoder().encode(enabled)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: encoded)
        #expect(decoded.claudeSwapShowSingleAccount == true)
    }

    @Test
    func `eligibility preserves explicit account and source intent`() {
        let eligibleSourceModes: [ProviderSourceMode?] = [nil, .auto]
        for sourceMode in eligibleSourceModes {
            #expect(CLIClaudeSwapCards.isEligible(
                provider: .claude,
                integrationEnabled: true,
                hasExplicitAccountSelection: false,
                sourceModeOverride: sourceMode))
        }

        for sourceMode in [ProviderSourceMode.web, .cli, .oauth, .api] {
            #expect(!CLIClaudeSwapCards.isEligible(
                provider: .claude,
                integrationEnabled: true,
                hasExplicitAccountSelection: false,
                sourceModeOverride: sourceMode))
        }

        #expect(!CLIClaudeSwapCards.isEligible(
            provider: .claude,
            integrationEnabled: false,
            hasExplicitAccountSelection: false,
            sourceModeOverride: nil))
        #expect(!CLIClaudeSwapCards.isEligible(
            provider: .claude,
            integrationEnabled: true,
            hasExplicitAccountSelection: true,
            sourceModeOverride: nil))
        #expect(!CLIClaudeSwapCards.isEligible(
            provider: .codex,
            integrationEnabled: true,
            hasExplicitAccountSelection: false,
            sourceModeOverride: nil))
    }

    @Test
    func `bypass does not invoke the adapter when single account cards are enabled`() async {
        let counter = InvocationCounter()
        let ambient = self.ambientOutput()
        let output = await CLIClaudeSwapCards.fetch(
            eligible: false,
            executablePath: "/unused/cswap",
            showSingleAccount: true,
            renderOptions: self.renderOptions(),
            ambientFetch: { ambient },
            accountListReader: { _ in
                await counter.increment()
                return ClaudeSwapAccountList(activeAccountNumber: nil, accounts: [])
            })

        #expect(await counter.value == 0)
        #expect(output.cards == ambient.cards)
    }

    @Test
    func `zero and one account lists retain ambient output`() async {
        let ambientCounter = InvocationCounter()
        let ambient = self.ambientOutput()
        for accounts in [[], [self.row(number: 1)]] {
            let output = await CLIClaudeSwapCards.fetch(
                eligible: true,
                executablePath: "/fake/cswap",
                renderOptions: self.renderOptions(),
                ambientFetch: {
                    await ambientCounter.increment()
                    return ambient
                },
                accountListReader: { _ in
                    ClaudeSwapAccountList(activeAccountNumber: nil, accounts: accounts)
                })
            #expect(output.cards == ambient.cards)
            #expect(output.cardFailures.isEmpty)
        }
        #expect(await ambientCounter.value == 2)
    }

    @Test
    func `single account option renders sentinel account instead of ambient output`() async {
        let ambientCounter = InvocationCounter()
        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: "/fake/cswap",
            showSingleAccount: true,
            renderOptions: self.renderOptions(),
            ambientFetch: {
                await ambientCounter.increment()
                return self.ambientOutput(failed: true)
            },
            accountListReader: { _ in
                ClaudeSwapAccountList(activeAccountNumber: 1, accounts: [
                    self.row(
                        number: 1,
                        active: true,
                        status: .tokenExpired,
                        email: "single@example.com",
                        hasUsage: false),
                ])
            })

        #expect(await ambientCounter.value == 0)
        #expect(output.exitCode == .success)
        #expect(output.cards.count == 1)
        #expect(output.cards.first?.accountLine == "single@example.com")
        #expect(output.cards.first?.isActive == true)
        #expect(output.cards.first?.accountProblem ==
            "Token expired. Switch to this account in claude-swap to refresh it.")
    }

    @Test
    func `multi account list skips ambient output and renders in active slot order`() async {
        let adapterCounter = InvocationCounter()
        let ambientCounter = InvocationCounter()
        let ambient = self.ambientOutput(failed: true)
        let list = ClaudeSwapAccountList(activeAccountNumber: 2, accounts: [
            self.row(number: 3),
            self.row(number: 2, active: true),
            self.row(number: 1),
        ])
        let status = ProviderStatusPayload(
            indicator: .minor,
            description: "Degraded performance",
            updatedAt: Date(timeIntervalSince1970: 0),
            url: "https://status.example.com")

        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: "/fake/cswap",
            renderOptions: self.renderOptions(status: status),
            ambientFetch: {
                await ambientCounter.increment()
                return ambient
            },
            accountListReader: { _ in
                await adapterCounter.increment()
                return list
            })

        #expect(await adapterCounter.value == 1)
        #expect(await ambientCounter.value == 0)
        #expect(output.cards.map(\.accountLine) == [
            "account-2@example.com",
            "account-1@example.com",
            "account-3@example.com",
        ])
        #expect(output.cards.map(\.isActive) == [true, false, false])
        #expect(output.cards.allSatisfy { $0.sourceLabel == "claude-swap" && $0.planBadge == nil })
        #expect(output.cards.allSatisfy { $0.statusLine == "Status: Partial outage – Degraded performance" })
        #expect(output.cardFailures.isEmpty)
        #expect(output.exitCode == .success)
    }

    @Test
    func `all sentinel rows remain successful metrics less cards`() async {
        let statuses: [ClaudeSwapUsageStatus] = [
            .apiKey,
            .tokenExpired,
            .keychainUnavailable,
            .noCredentials,
            .unavailable,
            .unknown("future_status"),
            .ok,
        ]
        let rows = statuses.enumerated().map { index, status in
            self.row(number: index + 1, status: status, hasUsage: false)
        }
        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: "/fake/cswap",
            renderOptions: self.renderOptions(),
            ambientFetch: { self.ambientOutput(failed: true) },
            accountListReader: { _ in
                ClaudeSwapAccountList(activeAccountNumber: nil, accounts: rows)
            })

        #expect(output.exitCode == .success)
        #expect(output.cards.count == statuses.count)
        #expect(output.cards.allSatisfy { $0.metrics.isEmpty && !$0.isActive })
        #expect(output.cards.map(\.accountProblem) == [
            "API-key account; subscription usage is unavailable.",
            "Token expired. Switch to this account in claude-swap to refresh it.",
            "claude-swap could not read the active account's Keychain entry.",
            "No stored credentials for this account slot.",
            "Usage fetch failed.",
            "Unrecognized claude-swap status: future_status",
            "No usage windows reported.",
        ])
    }

    @Test
    func `active sentinel account remains active and metrics less in full and brief cards`() async {
        let problem = "Usage fetch failed."
        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: "/fake/cswap",
            renderOptions: self.renderOptions(),
            ambientFetch: { self.ambientOutput(failed: true) },
            accountListReader: { _ in
                ClaudeSwapAccountList(activeAccountNumber: 1, accounts: [
                    self.row(
                        number: 1,
                        active: true,
                        status: .unavailable,
                        email: "active@example.com",
                        hasUsage: false),
                    self.row(number: 2),
                ])
            })

        #expect(output.exitCode == .success)
        #expect(output.cardFailures.isEmpty)
        #expect(output.cards.count == 2)
        let activeCard = output.cards.first
        #expect(activeCard?.accountLine == "active@example.com")
        #expect(activeCard?.isActive == true)
        #expect(activeCard?.accountProblem == problem)
        #expect(activeCard?.metrics.isEmpty == true)

        let rows = CLICardsBriefRenderer.makeRows(cards: activeCard.map { [$0] } ?? [])
        #expect(rows.count == 1)
        #expect(rows.first?.accountLabel == "active@example.com")
        #expect(rows.first?.isActive == true)
        #expect(rows.first?.accountProblem == problem)
        #expect(rows.first?.metricLabel == nil)
        #expect(rows.first?.usedPercent == nil)
    }

    @Test
    func `blank executable path preserves ambient output and fails distinctly`() async {
        let ambient = self.ambientOutput()
        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: "   ",
            renderOptions: self.renderOptions(),
            ambientFetch: { ambient })

        #expect(output.cards == ambient.cards)
        #expect(output.exitCode != .success)
        #expect(output.cardFailures == [CLICardFailure(
            provider: .claude,
            accountLabel: "claude-swap",
            message: "No claude-swap executable path is configured.")])
    }

    @Test
    func `adapter failures follow ambient failures and are bounded and sanitized`() async {
        let raw = "\u{1B}]0;owned\u{07}reader\r\nfailed\u{1B}[31m" + String(repeating: "x", count: 700)
        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: "   ",
            renderOptions: self.renderOptions(),
            ambientFetch: { self.ambientOutput(failed: true) },
            accountListReader: { _ in throw AdapterError(text: raw) })

        #expect(output.exitCode != .success)
        #expect(output.cards.first?.title == "Ambient Claude")
        #expect(output.cardFailures.map(\.accountLabel) == [nil, "claude-swap"])
        let diagnostic = output.cardFailures.last?.message ?? ""
        #expect(diagnostic.contains("reader  failed"))
        #expect(!diagnostic.contains("\u{1B}"))
        #expect(diagnostic.unicodeScalars.count == CLIClaudeSwapText.diagnosticScalarLimit)
    }

    @Test
    func `fake executable receives only one read only list command`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cards-claude-swap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("cswap")
        let invocationMarker = directory.appendingPathComponent("invoked", isDirectory: true)
        let duplicateMarker = directory.appendingPathComponent("duplicate")
        let script = """
        #!/bin/sh
        mkdir '\(invocationMarker.path)' || {
          touch '\(duplicateMarker.path)'
          exit 2
        }
        [ "$#" -eq 2 ] || exit 2
        [ "$1" = "--list" ] || exit 2
        [ "$2" = "--json" ] || exit 2
        cat <<'JSON'
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"email":"one@example.com","active":false,"usageStatus":"api_key"},
          {"number":2,"email":"two@example.com","active":true,"usageStatus":"unavailable"}
        ]}
        JSON
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let output = await CLIClaudeSwapCards.fetch(
            eligible: true,
            executablePath: executable.path,
            renderOptions: self.renderOptions(),
            ambientFetch: { self.ambientOutput() })

        #expect(output.exitCode == .success)
        #expect(output.cardFailures.isEmpty)
        #expect(output.cards.count == 2)
        #expect(FileManager.default.fileExists(atPath: invocationMarker.path))
        #expect(!FileManager.default.fileExists(atPath: duplicateMarker.path))
    }

    @Test
    func `cancellation drains the adapter child and preserves ambient output`() async {
        let cancellationCount = InvocationCounter()
        let ambient = self.ambientOutput()
        let task = Task {
            await CLIClaudeSwapCards.fetch(
                eligible: true,
                executablePath: "/fake/cswap",
                renderOptions: self.renderOptions(),
                ambientFetch: { ambient },
                accountListReader: { _ in
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return ClaudeSwapAccountList(activeAccountNumber: nil, accounts: [])
                    } catch {
                        await cancellationCount.increment()
                        throw error
                    }
                })
        }
        await Task.yield()
        task.cancel()
        let output = await task.value

        #expect(await cancellationCount.value == 1)
        #expect(output.cards == ambient.cards)
        #expect(output.cardFailures.last?.accountLabel == "claude-swap")
        #expect(output.exitCode != .success)
    }
}

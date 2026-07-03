import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIOutputTests {
    @Test
    func `output preferences json only forces JSON`() {
        let output = CLIOutputPreferences.from(argv: ["--json-only"])
        #expect(output.jsonOnly == true)
        #expect(output.format == .json)
    }

    @Test
    func `cli error payload is JSON array`() throws {
        let payload = CodexBarCLI.makeCLIErrorPayload(
            message: "Nope",
            code: .failure,
            kind: .args,
            pretty: false)
        #expect(payload != nil)
        let data = payload?.data(using: .utf8) ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(json?.isEmpty == false)
        let first = json?.first as? [String: Any]
        #expect(first?["provider"] as? String == "cli")
        let error = first?["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Nope")
    }

    @Test
    func `exit omits generic error when command already emitted payload`() {
        #expect(!CodexBarCLI.shouldPrintExitError(code: .success, message: nil))
        #expect(!CodexBarCLI.shouldPrintExitError(code: .failure, message: nil))
        #expect(CodexBarCLI.shouldPrintExitError(code: .failure, message: "Nope"))
    }

    @Test
    func `text renderer includes deepgram usage metrics`() {
        let deepgram = DeepgramUsageSnapshot(
            projectID: "project-123",
            start: "2026-05-10",
            end: "2026-05-17",
            hours: 12.5,
            totalHours: 14,
            agentHours: 1.25,
            tokensIn: 100,
            tokensOut: 50,
            ttsCharacters: 1200,
            requests: 42,
            updatedAt: Date(timeIntervalSince1970: 0))
        let text = CLIRenderer.renderText(
            provider: .deepgram,
            snapshot: deepgram.toUsageSnapshot(),
            credits: nil,
            context: RenderContext(
                header: "Deepgram (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Requests: 42"))
        #expect(text.contains("Usage: 12.5 audio hours · 14 billable hours"))
        #expect(text.contains("Usage: 1.2 agent hours · 150 tokens · 1,200 TTS chars"))
        #expect(text.contains("Period: 2026-05-10 to 2026-05-17"))
    }

    @Test
    func `text renderer includes amp credits without free tier usage`() {
        let snapshot = AmpUsageSnapshot(
            freeQuota: nil,
            freeUsed: nil,
            hourlyReplenishment: nil,
            windowHours: nil,
            individualCredits: 25.64,
            workspaceBalances: [
                AmpWorkspaceBalance(name: "Alpha Team", remaining: 1234.56),
            ],
            accountEmail: "paid@example.com",
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .amp,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Amp (cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Individual credits: $25.64"))
        #expect(text.contains("Workspace Alpha Team: $1,234.56"))
        #expect(text.contains("Account: paid@example.com"))
        #expect(!text.contains("Amp Free:"))
    }

    @Test
    func `text renderer shows mimo balance without quota or reset text`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            cashBalance: 20,
            giftBalance: 5.51,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .mimo,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Xiaomi MiMo (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Balance: $25.51 (Paid: $20.00 / Granted: $5.51)"))
        #expect(!text.contains("100%"))
        #expect(!text.contains("Resets"))
        #expect(!text.contains("Plan: Balance"))
    }

    @Test
    func `text renderer shows mimo token credits and balance`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            planCode: "standard",
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .mimo,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Xiaomi MiMo (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Credits: 90% left"))
        #expect(text.contains("Balance: $25.51"))
        #expect(text.contains("Plan: Standard"))
        #expect(!text.contains("Window: 100%"))
    }

    @Test
    func `text renderer includes crossmodel balance and usage`() {
        let snapshot = CrossModelUsageSnapshot(
            currency: "USD",
            balance: 8.059489,
            uncollected: 0,
            daily: Self.crossModelWindow(cost: 0.005746, totalTokens: 12467, requestCount: 9),
            weekly: Self.crossModelWindow(cost: 0.665033, totalTokens: 1_925_790, requestCount: 529),
            monthly: Self.crossModelWindow(cost: 5.368746, totalTokens: 35_412_471, requestCount: 3166),
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .crossmodel,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "CrossModel (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Balance: $8.06"))
        #expect(text.contains("Today: $0.01 · 12K tokens"))
        #expect(text.contains("Week: $0.67 · 529 requests"))
        #expect(text.contains("Month: $5.37 · 3.2K requests"))
        #expect(text.contains("Plan: Api Key"))
    }

    @Test
    func `text renderer preserves crossmodel non USD currency`() {
        let snapshot = CrossModelUsageSnapshot(
            currency: "EUR",
            balance: 8.059489,
            uncollected: 0,
            daily: Self.crossModelWindow(cost: 0.005746, totalTokens: 12467, requestCount: 9),
            weekly: Self.crossModelWindow(cost: 0.665033, totalTokens: 1_925_790, requestCount: 529),
            monthly: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .crossmodel,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "CrossModel (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Balance: €8.06"))
        #expect(text.contains("Today: €0.01 · 12K tokens"))
        #expect(text.contains("Week: €0.67 · 529 requests"))
        #expect(!text.contains("$"))
    }

    private static func crossModelWindow(
        cost: Double,
        totalTokens: Int,
        requestCount: Int) -> CrossModelUsageWindow
    {
        CrossModelUsageWindow(
            cost: cost,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: totalTokens,
            requestCount: requestCount,
            successCount: requestCount)
    }
}

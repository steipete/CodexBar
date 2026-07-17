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
    func `text renderer preserves compact mimo local summary casing`() {
        let summary = "Local · 1.5k total · 42 sessions · stale 34d"
        let snapshot = MiMoUsageSnapshot(
            balance: 0,
            currency: "",
            planCode: summary,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot(includeBalance: false)

        let text = CLIRenderer.renderText(
            provider: .mimo,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Xiaomi MiMo (local)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(CLIRenderer.planBadgeText(provider: .mimo, snapshot: snapshot) == summary)
        #expect(text.contains("Plan: \(summary)"))
        #expect(!text.contains("Stale 34D"))
    }
}

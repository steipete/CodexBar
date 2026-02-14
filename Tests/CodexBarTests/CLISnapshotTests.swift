import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

@Suite
struct CLISnapshotTests {
    @Test
    func rendersTextSnapshotForCodex() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: .init(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: "Fri at 9:00 AM"),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: CreditsSnapshot(remaining: 42, events: [], updatedAt: Date()),
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: ProviderStatusPayload(
                    indicator: .minor,
                    description: "Degraded performance",
                    updatedAt: Date(timeIntervalSince1970: 0),
                    url: "https://status.example.com"),
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Codex 1.2.3 (codex-cli)"))
        #expect(output.contains("Status: Partial outage – Degraded performance"))
        #expect(output.contains("Codex"))
        #expect(output.contains("Session: 88% left"))
        #expect(output.contains("Weekly: 75% left"))
        #expect(output.contains("Credits: 42"))
        #expect(output.contains("Account: user@example.com"))
        #expect(output.contains("Plan: Pro"))
    }

    @Test
    func rendersTextSnapshotForClaudeWithoutWeekly() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 2, windowMinutes: nil, resetsAt: nil, resetDescription: "3pm (Europe/Vienna)"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Session: 98% left"))
        #expect(!output.contains("Weekly:"))
    }

    @Test
    func rendersWarpUnlimitedAsDetailNotReset() {
        let meta = ProviderDescriptorRegistry.descriptor(for: .warp).metadata
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "Unlimited"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: ProviderIdentitySnapshot(
                providerID: .warp,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let output = CLIRenderer.renderText(
            provider: .warp,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Warp 0.0.0 (warp)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("\(meta.sessionLabel): 100% left"))
        #expect(!output.contains("Resets Unlimited"))
        #expect(output.contains("Unlimited"))
    }

    @Test
    func rendersWarpCreditsAsDetailAndResetAsDate() {
        let meta = ProviderDescriptorRegistry.descriptor(for: .warp).metadata
        let now = Date(timeIntervalSince1970: 0)
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "10/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .warp,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let output = CLIRenderer.renderText(
            provider: .warp,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Warp 0.0.0 (warp)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("\(meta.sessionLabel): 90% left"))
        #expect(output.contains("Resets"))
        #expect(output.contains("10/100 credits"))
        #expect(!output.contains("Resets 10/100 credits"))
    }

    @Test
    func rendersPaceLineWhenWeeklyHasReset() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Pace:"))
    }

    @Test
    func rendersJSONPayload() throws {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 10, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: "1.2.3",
            source: "codex-cli",
            status: ProviderStatusPayload(
                indicator: .none,
                description: nil,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_010),
                url: "https://status.example.com"),
            usage: snap,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode JSON payload")
            return
        }

        #expect(json.contains("\"provider\":\"codex\""))
        #expect(json.contains("\"version\":\"1.2.3\""))
        #expect(json.contains("\"status\""))
        #expect(json.contains("status.example.com"))
        #expect(json.contains("\"primary\""))
        #expect(json.contains("\"windowMinutes\":300"))
        #expect(json.contains("1700000000"))
    }

    @Test
    func encodesJSONWithSecondaryNullWhenMissing() throws {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snap)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode JSON payload")
            return
        }

        #expect(json.contains("\"secondary\":null"))
    }

    @Test
    func parsesOutputFormat() {
        #expect(OutputFormat(argument: "json") == .json)
        #expect(OutputFormat(argument: "TEXT") == .text)
        #expect(OutputFormat(argument: "invalid") == nil)
    }

    @Test
    func defaultsToUsageWhenNoCommandProvided() {
        #expect(CodexBarCLI.effectiveArgv([]) == ["usage"])
        #expect(CodexBarCLI.effectiveArgv(["--format", "json"]).first == "usage")
        #expect(CodexBarCLI.effectiveArgv(["usage", "--format", "json"]).first == "usage")
    }

    @Test
    func statusLineIsLastAndColoredWhenTTY() {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.58 (claude)",
                status: ProviderStatusPayload(
                    indicator: .critical,
                    description: "Major outage",
                    updatedAt: nil,
                    url: "https://status.claude.com"),
                useColor: true,
                resetStyle: .absolute))

        let lines = output.split(separator: "\n")
        #expect(lines.last?.contains("Status: Critical issue – Major outage") == true)
        #expect(output.contains("\u{001B}[31mStatus")) // red for critical
    }

    @Test
    func outputHasAnsiWhenTTYEvenWithoutStatus() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: true,
                resetStyle: .absolute))

        #expect(output.contains("\u{001B}["))
    }

    @Test
    func ttyOutputColorsHeaderAndUsage() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 95, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 80, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: true,
                resetStyle: .absolute))

        #expect(output.contains("\u{001B}[1;95m== Codex 0.0.0 (codex-cli) ==\u{001B}[0m"))
        #expect(output.contains("Session: \u{001B}[31m5% left\u{001B}[0m")) // red <10% left
        #expect(output.contains("Weekly: \u{001B}[33m20% left\u{001B}[0m")) // yellow <25% left
    }

    @Test
    func statusLineIsPlainWhenNoTTY() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.6.0 (codex-cli)",
                status: ProviderStatusPayload(
                    indicator: .none,
                    description: "Operational",
                    updatedAt: nil,
                    url: "https://status.openai.com/"),
                useColor: false,
                resetStyle: .absolute))

        #expect(!output.contains("\u{001B}["))
        #expect(output.contains("Status: Operational – Operational"))
    }
}

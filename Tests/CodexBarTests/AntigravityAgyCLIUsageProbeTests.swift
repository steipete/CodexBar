import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityAgyCLIUsageProbeTests {
    @Test
    func `parses model quota panel from agy usage output`() throws {
        let sample = """
        └ Model Quota
        Gemini 3.5 Flash (Medium)
        ███████████ ███████████ ███████████ ███████████ ███████████ 100%
        Quota available
        Gemini 3.1 Pro (High)
        ███████████ ███████████ ███████████ ███████████ ███████████ 75%
        Quota available
        Claude Sonnet 4.6 (Thinking)
        ███████████ ███████████ ███████████ ███████████ ███████████ 100%
        Quota available
        Claude Opus 4.6 (Thinking)
        ███████████ ███████████ ███████████ ███████████ ███████████ 50%
        Quota available
        (1–30 of 33 lines)
        ↑/↓ Scroll · pgup/pgdown Page · esc Close
        """

        let quotas = try AntigravityAgyCLIUsageProbe.parseUsageOutput(sample)

        #expect(quotas.count == 4)
        #expect(quotas.contains { $0.label == "Claude Sonnet 4.6 (Thinking)" && $0.remainingFraction == 1.0 })
        #expect(quotas.contains { $0.label == "Claude Opus 4.6 (Thinking)" && $0.remainingFraction == 0.5 })
        #expect(quotas.contains { $0.label == "Gemini 3.1 Pro (High)" && $0.remainingFraction == 0.75 })
    }

    @Test
    func `merge prefers cli quotas over remote and gemini`() {
        let gemini = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelId: "gemini-2.5-pro",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "user@example.com",
            accountPlan: "Paid")
        let remote = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6 (Thinking)",
                    modelId: "claude-sonnet-4-6-thinking",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "user@example.com",
            accountPlan: "Paid")
        let cli = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6 (Thinking)",
                    modelId: "claude-sonnet-4-6-thinking",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "cli@example.com",
            accountPlan: nil)

        let merged = AntigravityAgyStatusProbe.mergeSnapshots(cli: cli, remote: remote, gemini: gemini)

        #expect(merged.modelQuotas.count == 2)
        #expect(merged.modelQuotas.contains { $0.modelId == "claude-sonnet-4-6-thinking" && $0.remainingFraction == 0.8 })
        #expect(merged.modelQuotas.contains { $0.modelId == "gemini-2.5-pro" && $0.remainingFraction == 1.0 })
    }
}

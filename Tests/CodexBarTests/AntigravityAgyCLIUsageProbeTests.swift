import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityAgyCLIUsageProbeTests {
    @Test
    func `parses model quota panel with ANSI color codes`() throws {
        // Real `agy /usage` output is wrapped in ANSI CSI sequences (bold labels, colored bars,
        // truecolor percent). A previous ANSI-strip regex was invalid ICU syntax and silently stripped
        // nothing, so labels began with ESC (not a letter) and percent lines ended in `…100%␛[m` —
        // both detectors failed and the panel was reported "not found". This locks in the strip path.
        let esc = "\u{001B}"
        let bar = "\(esc)[32m███████████\(esc)[m \(esc)[32m███████████\(esc)[38;2;154;160;166m"
        let sample = """
        \(esc)[1m└ Model Quota\(esc)[m
        \(esc)[1mGemini 3.5 Flash (Medium)\(esc)[m
        \(bar) 100%\(esc)[m\(esc)[K
        \(esc)[2mQuota available\(esc)[m
        \(esc)[1mClaude Sonnet 4.6 (Thinking)\(esc)[m
        \(bar) 50%\(esc)[m\(esc)[K
        \(esc)[2mQuota available\(esc)[m
        \(esc)[1mClaude Opus 4.6 (Thinking)\(esc)[m
        \(bar) 0%\(esc)[m\(esc)[K
        \(esc)[38;2;154;160;166m  (1–30 of 33 lines)\(esc)[m
        """

        let quotas = try AntigravityAgyCLIUsageProbe.parseUsageOutput(sample)

        #expect(quotas.count == 3)
        #expect(quotas.contains { $0.label == "Gemini 3.5 Flash (Medium)" && $0.remainingFraction == 1.0 })
        #expect(quotas.contains { $0.label == "Claude Sonnet 4.6 (Thinking)" && $0.remainingFraction == 0.5 })
        #expect(quotas.contains { $0.label == "Claude Opus 4.6 (Thinking)" && $0.remainingFraction == 0.0 })
    }

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

    @Test
    func `merge drops misleading Gemini free-tier plan label`() {
        // agy `/usage` exposes no account plan, so cli.accountPlan is nil and the merge falls back
        // to the Gemini Code Assist lookup, which reports "Free" for a paid Antigravity account.
        // That label describes the Gemini lane, not the account, so it must not surface as the plan.
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
            accountPlan: "Free")
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

        let merged = AntigravityAgyStatusProbe.mergeSnapshots(cli: cli, remote: nil, gemini: gemini)

        #expect(merged.accountPlan == nil)
    }

    @Test
    func `merge keeps a concrete paid plan label`() {
        let gemini = AntigravityStatusSnapshot(
            modelQuotas: [],
            accountEmail: "user@example.com",
            accountPlan: "Paid")
        let cli = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Opus 4.6 (Thinking)",
                    modelId: "claude-opus-4-6-thinking",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "cli@example.com",
            accountPlan: nil)

        let merged = AntigravityAgyStatusProbe.mergeSnapshots(cli: cli, remote: nil, gemini: gemini)

        #expect(merged.accountPlan == "Paid")
    }
}

import CodexBarCore
import Testing
@testable import CodexBarCLI

struct CLIAntigravityFallbackSummaryTests {
    @Test
    func `summary includes ordered per-source outcomes`() {
        let attempts = [
            ProviderFetchAttempt(
                strategyID: "antigravity.app-local",
                kind: .localProbe,
                wasAvailable: true,
                errorDescription: "Antigravity quota request rejected."),
            ProviderFetchAttempt(
                strategyID: "antigravity.cli-https",
                kind: .cli,
                wasAvailable: false,
                errorDescription: nil),
            ProviderFetchAttempt(
                strategyID: "antigravity.ide-local",
                kind: .localProbe,
                wasAvailable: true,
                errorDescription: "Antigravity language server not detected. Launch Antigravity and retry."),
        ]

        let summary = CodexBarCLI.antigravityAutoFallbackSummary(
            provider: .antigravity,
            sourceMode: .auto,
            attempts: attempts)
        let expected = [
            "Antigravity auto source outcomes: app: Antigravity quota request rejected.",
            " -> cli: skipped (unavailable)",
            " -> ide: Antigravity language server not detected. Launch Antigravity and retry.",
        ].joined()

        #expect(summary == expected)
    }

    @Test
    func `summary is nil outside antigravity auto failures`() {
        let attempts = [
            ProviderFetchAttempt(
                strategyID: "antigravity.cli-https",
                kind: .cli,
                wasAvailable: true,
                errorDescription: "example"),
        ]

        #expect(CodexBarCLI.antigravityAutoFallbackSummary(
            provider: .antigravity,
            sourceMode: .cli,
            attempts: attempts) == nil)
        #expect(CodexBarCLI.antigravityAutoFallbackSummary(
            provider: .kilo,
            sourceMode: .auto,
            attempts: attempts) == nil)
        #expect(CodexBarCLI.antigravityAutoFallbackSummary(
            provider: .antigravity,
            sourceMode: .auto,
            attempts: []) == nil)
    }
}

import CodexBarCore
import Foundation
import Testing

@Suite
struct GeminiStatusProbeTests {
    /// Sample /stats output from Gemini CLI (actual format with box-drawing chars)
    static let sampleStatsOutput = """
    │  Model Usage                            Reqs                  Usage left  │
    │  ───────────────────────────────────────────────────────────────────────  │
    │  gemini-2.5-flash                          -   99.8% (Resets in 20h 37m)  │
    │  gemini-2.5-flash-lite                     -   99.8% (Resets in 20h 37m)  │
    │  gemini-2.5-pro                            -      100.0% (Resets in 24h)  │
    │  gemini-3-pro-preview                      -      100.0% (Resets in 24h)  │
    """

    // MARK: - Legacy CLI parsing tests (kept for fallback support)

    @Test
    func parsesMinimumPercentFromMultipleModels() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        #expect(snap.dailyPercentLeft == 99.8)
        #expect(snap.resetDescription == "Resets in 20h 37m")
    }

    @Test
    func parsesLowerPercentCorrectly() throws {
        let output = """
        │  Model Usage                                                  Reqs                  Usage left  │
        │  gemini-2.5-flash                                               10       85.5% (Resets in 12h)  │
        │  gemini-2.5-pro                                                  5       92.0% (Resets in 12h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)
        #expect(snap.dailyPercentLeft == 85.5)
        #expect(snap.resetDescription == "Resets in 12h")
    }

    @Test
    func handlesZeroPercentUsage() throws {
        let output = """
        │  gemini-2.5-flash                                               50        0.0% (Resets in 6h)  │
        │  gemini-2.5-pro                                                 20       15.0% (Resets in 6h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)
        #expect(snap.dailyPercentLeft == 0.0)
        #expect(snap.resetDescription == "Resets in 6h")
    }

    @Test
    func handles100PercentRemaining() throws {
        let output = """
        │  gemini-2.5-flash                                                -      100.0% (Resets in 24h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)
        #expect(snap.dailyPercentLeft == 100.0)
    }

    @Test
    func throwsOnEmptyOutput() {
        #expect(throws: GeminiStatusProbeError.self) {
            try GeminiStatusProbe.parse(text: "")
        }
    }

    @Test
    func throwsOnNoUsageData() {
        let output = """
        Welcome to Gemini CLI!
        Type /help for available commands.
        """
        #expect(throws: GeminiStatusProbeError.self) {
            try GeminiStatusProbe.parse(text: output)
        }
    }

    @Test
    func stripsANSICodesBeforeParsing() throws {
        let output =
            "\u{1B}[32m│\u{1B}[0m  gemini-2.5-flash                                                -       75.5% " +
            "(Resets in 18h)  │"
        let snap = try GeminiStatusProbe.parse(text: output)
        #expect(snap.dailyPercentLeft == 75.5)
    }

    @Test
    func preservesRawText() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        #expect(snap.rawText == Self.sampleStatsOutput)
        #expect(snap.accountEmail == nil) // Legacy parse doesn't extract email
        #expect(snap.accountPlan == nil)
    }

    @Test
    func parsesVariousResetDescriptions() throws {
        let cases: [(String, String)] = [
            ("Resets in 24h", "Resets in 24h"),
            ("Resets in 1h 30m", "Resets in 1h 30m"),
            ("Resets tomorrow", "Resets tomorrow"),
        ]
        for (resetStr, expected) in cases {
            let output = """
            │  gemini-2.5-flash                                                -       50.0% (\(resetStr))  │
            """
            let snap = try GeminiStatusProbe.parse(text: output)
            #expect(snap.resetDescription == expected)
        }
    }

    @Test
    func throwsNotLoggedInOnAuthPrompt() {
        let authOutputs = [
            "Waiting for auth... (Press ESC or CTRL+C to cancel)",
            "Login with Google\nUse Gemini API key",
            "Some preamble\nWaiting for auth\nMore text",
        ]
        for output in authOutputs {
            #expect(throws: GeminiStatusProbeError.notLoggedIn) {
                try GeminiStatusProbe.parse(text: output)
            }
        }
    }

    // MARK: - Model quota grouping tests

    @Test
    func parsesModelsIntoQuotaArray() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        // Should parse multiple models (exact count may change as Google adds/removes models)
        #expect(snap.modelQuotas.count >= 2)

        // All model IDs should start with "gemini"
        for quota in snap.modelQuotas {
            #expect(quota.modelId.hasPrefix("gemini"))
        }
    }

    @Test
    func lowestPercentLeftReturnsMinimum() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        // Flash models are 99.8%, Pro models are 100%, so min should be 99.8
        #expect(snap.lowestPercentLeft == 99.8)
    }

    @Test
    func tierGroupingByKeyword() throws {
        // Test that flash/pro keyword filtering works (model names may change)
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)

        let flashQuotas = snap.modelQuotas.filter { $0.modelId.contains("flash") }
        let proQuotas = snap.modelQuotas.filter { $0.modelId.contains("pro") }

        // Should have at least one of each tier in sample
        #expect(!flashQuotas.isEmpty)
        #expect(!proQuotas.isEmpty)
    }

    @Test
    func tierMinimumCalculation() throws {
        // Use controlled test data to verify min-per-tier logic
        // Model names must start with "gemini-" to match the parser regex
        let output = """
        │  gemini-a-flash                            10       85.0% (Resets in 24h)  │
        │  gemini-b-flash                             5       92.0% (Resets in 24h)  │
        │  gemini-c-pro                               2       95.0% (Resets in 24h)  │
        │  gemini-d-pro                               1       99.0% (Resets in 24h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)

        let flashQuotas = snap.modelQuotas.filter { $0.modelId.contains("flash") }
        let proQuotas = snap.modelQuotas.filter { $0.modelId.contains("pro") }

        let flashMin = flashQuotas.min(by: { $0.percentLeft < $1.percentLeft })
        let proMin = proQuotas.min(by: { $0.percentLeft < $1.percentLeft })

        #expect(flashMin?.percentLeft == 85.0)
        #expect(proMin?.percentLeft == 95.0)
    }

    @Test
    func quotasHaveResetDescriptions() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)

        // At least some quotas should have reset descriptions
        let hasResets = snap.modelQuotas.contains { $0.resetDescription != nil }
        #expect(hasResets)
    }

    // MARK: - Live API test

    @Test
    func liveGeminiFetch() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_GEMINI_FETCH"] == "1" else {
            return
        }
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        print(
            """
            Live Gemini usage (via API):
            models: \(snap.modelQuotas.map { "\($0.modelId): \($0.percentLeft)%" }.joined(separator: ", "))
            lowest: \(snap.lowestPercentLeft ?? -1)% left
            """)
        #expect(!snap.modelQuotas.isEmpty)
    }
}

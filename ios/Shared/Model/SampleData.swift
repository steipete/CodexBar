import Foundation

/// Sample snapshot for SwiftUI previews and DEBUG simulator runs (so the UI renders without a
/// live Mac). Never seeded in release builds.
public enum SampleData {
    public static func snapshot(generatedAt: Date = Date()) -> WidgetSnapshot {
        func entry(
            _ provider: UsageProvider,
            _ session: Double,
            _ weekly: Double,
            opus: Double? = nil,
            sessionCost: Double? = nil,
            monthCost: Double? = nil) -> WidgetSnapshot.ProviderEntry
        {
            var rows: [WidgetSnapshot.WidgetUsageRowSnapshot] = [
                .init(id: "primary", title: "Session", percentLeft: session),
                .init(id: "secondary", title: "Weekly", percentLeft: weekly),
            ]
            if let opus { rows.append(.init(id: "tertiary", title: "Opus", percentLeft: opus)) }
            let token: WidgetSnapshot.TokenUsageSummary? = sessionCost.map {
                .init(
                    sessionCostUSD: $0,
                    sessionTokens: Int($0 * 120_000),
                    last30DaysCostUSD: monthCost,
                    last30DaysTokens: monthCost.map { Int($0 * 120_000) },
                    currencyCode: "USD")
            }
            let daily: [WidgetSnapshot.DailyUsagePoint] = (0..<14).map { i in
                .init(
                    dayKey: "2026-06-\(String(format: "%02d", 14 + i))",
                    totalTokens: Int.random(in: 40_000...900_000, using: &Self.seededRNG),
                    costUSD: Double.random(in: 0.4...9.5, using: &Self.seededRNG))
            }
            return .init(
                provider: provider,
                updatedAt: generatedAt,
                primary: RateWindow(usedPercent: 100 - session, windowMinutes: 300),
                secondary: RateWindow(usedPercent: 100 - weekly, windowMinutes: 10_080),
                tertiary: opus.map { RateWindow(usedPercent: 100 - $0) },
                usageRows: rows,
                creditsRemaining: provider == .codex ? 42 : nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: token,
                dailyUsage: daily)
        }

        return WidgetSnapshot(
            entries: [
                entry(.codex, 68, 34, sessionCost: 2.4, monthCost: 58),
                entry(.claude, 12, 47, opus: 80, sessionCost: 4.1, monthCost: 91),
                entry(.cursor, 55, 71, sessionCost: 1.2, monthCost: 22),
                entry(.copilot, 88, 62),
                entry(.gemini, 6, 19),
            ],
            enabledProviders: [.codex, .claude, .cursor, .copilot, .gemini],
            usageBarsShowUsed: false,
            generatedAt: generatedAt)
    }

    // Deterministic RNG so previews/screenshots are stable.
    nonisolated(unsafe) private static var seededRNG = SeededGenerator(seed: 42)

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

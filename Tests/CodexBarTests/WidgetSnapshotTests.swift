import Foundation
import Testing
@testable import CodexBarCore

struct WidgetSnapshotTests {
    @Test
    func `widget snapshot round trip`() throws {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Date(),
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "session", title: "Session", percentLeft: 90),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "weekly", title: "Weekly", percentLeft: 80),
            ],
            creditsRemaining: 123.4,
            codeReviewRemainingPercent: 80,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 12.3,
                sessionTokens: 1200,
                last30DaysCostUSD: 456.7,
                last30DaysTokens: 9800),
            dailyUsage: [
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-20", totalTokens: 1200, costUSD: 12.3),
            ])

        let snapshot = WidgetSnapshot(
            entries: [entry],
            enabledProviders: [.codex, .claude],
            generatedAt: Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.entries.count == 1)
        #expect(decoded.entries.first?.provider == .codex)
        #expect(decoded.entries.first?.tokenUsage?.sessionTokens == 1200)
        #expect(decoded.entries.first?.usageRows?.map(\.id) == ["session", "weekly"])
        #expect(decoded.enabledProviders == [.codex, .claude])
    }

    @Test
    func `widget snapshot round trip preserves kilo provider`() throws {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .kilo,
            updatedAt: Date(),
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "40/100 credits"),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 1.25,
                sessionTokens: 4200,
                last30DaysCostUSD: 19.75,
                last30DaysTokens: 58000),
            dailyUsage: [
                WidgetSnapshot.DailyUsagePoint(dayKey: "2026-02-27", totalTokens: 4200, costUSD: 1.25),
            ])

        let snapshot = WidgetSnapshot(
            entries: [entry],
            enabledProviders: [.kilo, .codex],
            generatedAt: Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.entries.first?.provider == .kilo)
        #expect(decoded.entries.first?.primary?.resetDescription == "40/100 credits")
        #expect(decoded.enabledProviders == [.kilo, .codex])
    }

    @Test
    func `widget snapshot round trip preserves kilo zero total edge state`() throws {
        let now = Date()
        let kiloSnapshot = KiloUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 0,
            creditsRemaining: 0,
            planName: "Kilo Pass Pro",
            autoTopUpEnabled: true,
            autoTopUpMethod: "visa",
            updatedAt: now).toUsageSnapshot()

        let entry = WidgetSnapshot.ProviderEntry(
            provider: .kilo,
            updatedAt: now,
            primary: kiloSnapshot.primary,
            secondary: kiloSnapshot.secondary,
            tertiary: kiloSnapshot.tertiary,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let snapshot = WidgetSnapshot(
            entries: [entry],
            enabledProviders: [.kilo],
            generatedAt: now)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.entries.first?.provider == .kilo)
        #expect(decoded.entries.first?.primary?.usedPercent == 100)
        #expect(decoded.entries.first?.primary?.remainingPercent == 0)
        #expect(decoded.entries.first?.primary?.resetDescription == "0/0 credits")
        #expect(decoded.enabledProviders == [.kilo])
    }

    @Test
    func `widget snapshot decodes legacy payload without usage rows`() throws {
        let json = """
        {
          "entries": [
            {
              "provider": "codex",
              "updatedAt": "2026-04-04T06:30:00Z",
              "primary": null,
              "secondary": {
                "usedPercent": 25,
                "windowMinutes": 10080,
                "resetsAt": null,
                "resetDescription": null
              },
              "tertiary": null,
              "creditsRemaining": null,
              "codeReviewRemainingPercent": null,
              "tokenUsage": null,
              "dailyUsage": []
            }
          ],
          "enabledProviders": ["codex"],
          "generatedAt": "2026-04-04T06:30:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))

        #expect(decoded.entries.count == 1)
        #expect(decoded.entries.first?.usageRows == nil)
        #expect(decoded.entries.first?.secondary?.usedPercent == 25)
    }
}

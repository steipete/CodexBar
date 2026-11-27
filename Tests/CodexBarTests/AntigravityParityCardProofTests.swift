import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class AntigravityParityCardProofTests: XCTestCase {
    private static let width: CGFloat = 320

    func test_renderAntigravityParityCardProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_ANTIGRAVITY_PARITY_CARD_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ANTIGRAVITY_PARITY_CARD_DIR to render the Antigravity parity card proof.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 15,
            hour: 12)))
        let usage = try Self.makeUsageSnapshot(now: now)
        let tokenSnapshot = Self.makeTokenSnapshot(now: now)
        let metadata = try XCTUnwrap(ProviderDefaults.metadata[.antigravity])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: metadata,
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: "Google AI Ultra"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            costUsageBucketCalendar: calendar,
            now: now))

        XCTAssertEqual(model.metrics.count, 4)
        XCTAssertEqual(model.inlineUsageDashboard?.kpis.count, 6)
        XCTAssertFalse(model.inlineUsageDashboard?.quotaWindows.isEmpty ?? true)
        XCTAssertTrue(model.providerDetails.contains { $0.title == "Quota groups" })
        XCTAssertTrue(model.providerDetails.contains { $0.title == "Model catalog" })

        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = AnyView(UsageMenuCardView(model: model, width: Self.width)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 2)
            .environment(\.accessibilityEnabled, true)
            .background(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let png = try XCTUnwrap(
            MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting),
            "Antigravity parity card render failed")
        XCTAssertFalse(png.isEmpty)
        let outURL = directory.appendingPathComponent("antigravity-parity-card.png")
        try png.write(to: outURL, options: .atomic)
        let accessibility = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
        for required in [
            "Gemini 5-hour", "Claude/GPT 5-hour", "Recent windows", "Top model", "QUOTA GROUPS", "MODEL CATALOG",
        ] {
            XCTAssertTrue(accessibility.contains(required), "Missing \(required) in:\n\(accessibility)")
        }
    }

    private static func makeUsageSnapshot(now: Date) throws -> UsageSnapshot {
        let iso = ISO8601DateFormatter()
        let summaryJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini 3.1 Pro, Gemini 3 Flash. Resets regularly.",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "displayName": "5-hour",
                  "window": "5h",
                  "remainingFraction": 0.72,
                  "resetTime": "\(iso.string(from: now.addingTimeInterval(3 * 3600 + 20 * 60)))"
                },
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly",
                  "window": "weekly",
                  "remainingFraction": 0.81,
                  "resetTime": "\(iso.string(from: now.addingTimeInterval(5 * 86400 + 6 * 3600)))"
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Sonnet 4.6, GPT-OSS 120B. Shared pool.",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "displayName": "5-hour",
                  "window": "5h",
                  "remainingFraction": 0.64,
                  "resetTime": "\(iso.string(from: now.addingTimeInterval(2 * 3600 + 45 * 60)))"
                },
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly",
                  "window": "weekly",
                  "remainingFraction": 0.78,
                  "resetTime": "\(iso.string(from: now.addingTimeInterval(4 * 86400 + 18 * 3600)))"
                }
              ]
            }
          ]
        }
        """
        let baseUsage = try AntigravityStatusProbe.parseQuotaSummaryResponse(
            Data(summaryJSON.utf8)).toUsageSnapshot()
        let catalogDetails = try ProviderDetailSection(
            title: "Model catalog",
            rows: [
                ProviderDetailSection.Row(
                    id: "ag-cat-0",
                    label: "Gemini 3.1 Pro",
                    value: "1.5x · Premium · New"),
                ProviderDetailSection.Row(
                    id: "ag-cat-1",
                    label: "Claude Sonnet 4.6",
                    value: "1x · Standard"),
            ])
        return UsageSnapshot(
            primary: baseUsage.primary,
            secondary: baseUsage.secondary,
            tertiary: baseUsage.tertiary,
            extraRateWindows: baseUsage.extraRateWindows,
            providerCost: baseUsage.providerCost,
            details: baseUsage.details + [catalogDetails],
            antigravityCredits: baseUsage.antigravityCredits,
            antigravityAccountMetadata: baseUsage.antigravityAccountMetadata,
            antigravityCatalog: baseUsage.antigravityCatalog,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Google AI Ultra"))
    }

    private struct DailySeed {
        let date: String
        let input: Int
        let output: Int
        let requests: Int
        let cost: Double
        let models: [(String, Double, Int, Int)]
    }

    private static func makeTokenSnapshot(now: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 48_200_000,
            sessionCostUSD: 14.80,
            last30DaysTokens: 420_500_000,
            last30DaysCostUSD: 128.40,
            last30DaysRequests: 1420,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            daily: [
                self.makeEntry(DailySeed(
                    date: "2026-07-06",
                    input: 90_000_000,
                    output: 30_000_000,
                    requests: 380,
                    cost: 36.20,
                    models: [("gemini-3.1-pro", 36.20, 120_000_000, 380)])),
                self.makeEntry(DailySeed(
                    date: "2026-07-10",
                    input: 110_000_000,
                    output: 42_300_000,
                    requests: 510,
                    cost: 46.80,
                    models: [
                        ("gemini-3.1-pro", 32.10, 102_300_000, 350),
                        ("claude-sonnet-4-6", 14.70, 50_000_000, 160),
                    ])),
                self.makeEntry(DailySeed(
                    date: "2026-07-14",
                    input: 74_000_000,
                    output: 26_000_000,
                    requests: 340,
                    cost: 30.60,
                    models: [("gemini-3.1-pro", 30.60, 100_000_000, 340)])),
                self.makeEntry(DailySeed(
                    date: "2026-07-15",
                    input: 35_200_000,
                    output: 13_000_000,
                    requests: 190,
                    cost: 14.80,
                    models: [("gemini-3.1-pro", 14.80, 48_200_000, 190)])),
            ],
            updatedAt: now)
    }

    private static func makeEntry(_ seed: DailySeed) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: seed.date,
            inputTokens: seed.input,
            outputTokens: seed.output,
            totalTokens: seed.input + seed.output,
            requestCount: seed.requests,
            costUSD: seed.cost,
            modelsUsed: seed.models.map(\.0),
            modelBreakdowns: seed.models.map { model in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: model.0,
                    costUSD: model.1,
                    totalTokens: model.2,
                    requestCount: model.3)
            })
    }
}

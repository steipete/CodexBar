import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in proof using only synthetic transcripts and unshown content windows.
@MainActor
final class ClaudeIncompleteScreenshotRenderTests: XCTestCase {
    func test_renderIncompleteUsage() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_INCOMPLETE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_INCOMPLETE_PROOF_DIR to render synthetic incomplete-usage proof.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for before in [true, false] {
                let snapshot = try Self.snapshot(reconstructPriorAggregation: before)
                XCTAssertEqual(snapshot.daily.count, 3)
                XCTAssertEqual(snapshot.last30DaysCostUSD ?? -1, before ? 1.4848 : 0.84, accuracy: 0.000001)
                XCTAssertEqual(snapshot.daily.last?.incompleteRequestCount, before ? 0 : 1)
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: .claude,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[.claude]),
                    snapshot: nil,
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: snapshot,
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: nil),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: false,
                    resetTimeDisplayStyle: .countdown,
                    tokenCostUsageEnabled: true,
                    costSummaryInlineEnabled: false,
                    tokenCostMenuSectionEnabled: true,
                    costComparisonPeriodsEnabled: true,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: true,
                    usesLiveSubtitle: false,
                    preferredCurrencyCode: "USD",
                    costUsageBucketCalendar: ClaudeIncompleteUsagePropagationTests.calendar,
                    now: snapshot.updatedAt))
                for (appearance, scheme, theme) in [
                    (NSAppearance.Name.aqua, ColorScheme.light, "light"),
                    (NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"),
                ] {
                    let phase = before ? "before" : "after"
                    let view = AnyView(VStack(alignment: .leading, spacing: 12) {
                        Text(before ? "Before · preliminary estimates included" : "After · final usage only")
                            .font(.headline)
                        UsageMenuCardView(model: model, width: 380)
                        Divider()
                        CostHistoryChartMenuView(
                            provider: .claude,
                            daily: snapshot.daily,
                            totalCostUSD: snapshot.last30DaysCostUSD,
                            historyDays: 30,
                            hidePersonalInfo: true,
                            width: 380)
                    }
                    .padding(16)
                    .frame(width: 412)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.calendar, ClaudeIncompleteUsagePropagationTests.calendar)
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    .environment(\.colorScheme, scheme))
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: appearance)
                    let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    try png.write(to: directory.appendingPathComponent("claude-incomplete-\(phase)-\(theme).png"))
                }
            }
        }
    }

    private static func snapshot(reconstructPriorAggregation: Bool) throws -> CostUsageTokenSnapshot {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = ClaudeIncompleteUsagePropagationTests.now
        let calendar = ClaudeIncompleteUsagePropagationTests.calendar
        let samples = [
            (2, 100_000, 50000, false),
            (1, 200_000, 10000, false),
            (1, 161_200, 0, true),
            (0, 161_200, 0, true),
        ]
        let rows: [[String: Any]] = samples.enumerated().map { index, sample in
            let (offset, input, output, incomplete) = sample
            var usage = ["input_tokens": input, "output_tokens": output]
            if !incomplete { usage["cache_read_input_tokens"] = 0; usage["cache_creation_input_tokens"] = 0 }
            // Reconstruct the old parser's aggregate by admitting the exact preliminary counters.
            let stop: Any = incomplete && !reconstructPriorAggregation ? NSNull() : "end_turn"
            return [
                "type": "assistant",
                "sessionId": "synthetic-session-\(index)",
                "timestamp": env.isoString(for: now.addingTimeInterval(-Double(offset) * 86400)),
                "message": [
                    "id": "synthetic-response-\(index)",
                    "model": "gpt-5.6-sol",
                    "stop_reason": stop,
                    "usage": usage,
                ],
            ]
        }
        _ = try env.writeClaudeProjectFile(relativePath: "fixture/session.jsonl", contents: env.jsonl(rows))
        XCTAssertTrue(try ModelsDevCache.save(
            catalog: CostUsagePricingClaudeThresholdTests.catalog(),
            fetchedAt: now,
            cacheRoot: env.cacheRoot))
        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: now.addingTimeInterval(-2 * 86400),
            until: now,
            now: now,
            options: .init(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot, calendar: calendar))
        let today = report.data.last
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            last30DaysTokens: report.summary?.totalTokens,
            last30DaysCostUSD: report.summary?.totalCostUSD,
            costProvenance: .listPriceEstimate,
            daily: report.data,
            updatedAt: now)
    }
}

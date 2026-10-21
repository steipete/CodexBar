import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class CostHistoryModelNamesRenderTests: XCTestCase {
    func test_renderSyntheticConversationTitles() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CONVERSATION_TITLES_PROOF"] else {
            throw XCTSkip("Set CODEXBAR_CONVERSATION_TITLES_PROOF to render synthetic conversation proof")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessions = ["Python Complexity Tools", nil].enumerated().map { index, title in
            CostUsageSessionBreakdown(
                sessionID: index == 0 ? "01a10000-0000-0000-0000-00006c0a5925" : "01a10000-0000-0000-0000-000052829091",
                lastActivity: Date(timeIntervalSince1970: 1_791_676_800),
                inputTokens: 10000,
                cachedInputTokens: 2000,
                outputTokens: 1000,
                totalTokens: 11000,
                requestCount: 1,
                costUSD: index == 0 ? 0.88 : 0.17,
                modelBreakdowns: [.init(modelName: "gpt-5.4", costUSD: nil, totalTokens: 11000)],
                title: title)
        }
        let daily = [CostUsageDailyReport.Entry(
            date: "2026-10-11",
            inputTokens: 20000,
            outputTokens: 2000,
            totalTokens: 22000,
            costUSD: 1.05,
            modelsUsed: ["gpt-5.4"],
            modelBreakdowns: nil)]
        for hidden in [false, true] {
            let view = try CostHistoryChartMenuView(
                provider: .codex,
                daily: daily,
                totalCostUSD: 1.05,
                sessions: sessions,
                hidePersonalInfo: hidden,
                width: 320)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.timeZone, XCTUnwrap(TimeZone(secondsFromGMT: 0)))
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                .write(to: directory.appendingPathComponent(hidden ? "privacy.png" : "conversations.png"))
        }
    }

    func test_renderSyntheticNames() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_MODEL_NAMES_PROOF"] else {
            throw XCTSkip("Set CODEXBAR_MODEL_NAMES_PROOF to render synthetic chart proof")
        }
        let daily = [CostUsageDailyReport.Entry(
            date: "2026-09-27",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 12345,
            costUSD: nil,
            modelsUsed: ["fictional-model-a", "fictional-model-b"],
            modelBreakdowns: nil)]
        let view = CostHistoryChartMenuView(
            provider: .grok, daily: daily, totalCostUSD: nil, hidePersonalInfo: true, width: 320)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            .write(to: URL(fileURLWithPath: path))
    }
}

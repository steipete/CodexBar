import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class ProviderBreakdownScreenshotTests: XCTestCase {
    func test_renderSyntheticBreakdowns() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_BREAKDOWN_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_BREAKDOWN_SCREENSHOT_DIR to render synthetic provider breakdowns.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for enabled in [false, true] {
            let litellm = try await LiteLLMModelUsageTests.fetch(
                engine: .quickJS, scenario: enabled ? "normal" : "off")
            let costs = """
            {"data":[{"starting_at":"2026-09-24T00:00:00Z","ending_at":"2026-09-25T00:00:00Z","results":[
              {"amount":"1250","description":"Input tokens","workspace_id":"wrk_fixture"},
              {"amount":"75","description":"Output tokens","workspace_id":null}]}]}
            """
            let claude = try ClaudeAdminAPIUsageFetcher._parseSnapshotForTesting(
                costs: Data(costs.utf8),
                messages: Data(#"{"data":[]}"#.utf8),
                now: litellm.updatedAt,
                workspaceSpendEnabled: enabled).toUsageSnapshot()
            for (provider, snapshot) in [(UsageProvider.litellm, litellm), (.claude, claude)] {
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: provider,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[provider]),
                    snapshot: snapshot,
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: nil,
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: nil),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: true,
                    resetTimeDisplayStyle: .absolute,
                    tokenCostUsageEnabled: false,
                    costSummaryInlineEnabled: true,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: false,
                    usesLiveSubtitle: false,
                    now: snapshot.updatedAt))
                let view = AnyView(UsageMenuCardView(model: model, width: 440)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory
                        .appendingPathComponent("\(provider.rawValue)-\(enabled ? "after" : "before").png"))
            }
        }
    }
}

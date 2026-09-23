import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class LLMManScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticUsage() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LLMMAN_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_LLMMAN_SCREENSHOT_DIR to render synthetic llmman usage.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = try await LLMManPluginTests.fetch(engine: .quickJS)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .llmman,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.llmman]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .llmman)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: snapshot.updatedAt))
        let view = AnyView(UsageMenuCardView(model: model, width: 380)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, 2)
            .background(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            .write(to: directory.appendingPathComponent("llmman-synthetic.png"))
    }
}

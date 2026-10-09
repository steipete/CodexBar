import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class AccountAPIProviderScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticUsage() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACCOUNT_API_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ACCOUNT_API_SCREENSHOT_DIR to render synthetic account API usage.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cosmic = try await CosmicPluginTests.fetch(CosmicPluginTests.fixture, engine: .quickJS)
        let aerostack = try await AerostackPluginTests.fetch(AerostackPluginTests.fixture, engine: .quickJS)
        let sail = try await SailResearchPluginTests.fetch(engine: .quickJS)
        let sofya = try await SofyaPluginTests.fetch(engine: .quickJS)
        for (provider, snapshot) in [
            (UsageProvider.cosmic, cosmic), (.aerostack, aerostack), (.sailresearch, sail), (.sofya, sofya),
        ] {
            let model = try UsageMenuCardView.Model.make(.init(
                provider: provider,
                metadata: XCTUnwrap(ProviderDefaults.metadata[provider]),
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: provider)),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .absolute,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                usesLiveSubtitle: false,
                now: snapshot.updatedAt))
            let view = AnyView(UsageMenuCardView(model: model, width: 420)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light)
                .environment(\.displayScale, 2)
                .background(Color(nsColor: .windowBackgroundColor)))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                .write(to: directory.appendingPathComponent("\(provider.rawValue)-synthetic.png"))
        }
    }
}

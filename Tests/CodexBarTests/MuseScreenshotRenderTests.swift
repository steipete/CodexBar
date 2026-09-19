import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class MuseScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticPluginParity() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_MUSE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_MUSE_SCREENSHOT_DIR to render synthetic Muse cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let after = try await MusePluginTests.fetch(MusePluginTests.account, engine: .quickJS)
        // Golden snapshot from the original Swift proposal for the same synthetic response.
        let before = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 96,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_788_599_502),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 1_788_739_200),
                resetDescription: nil),
            details: [ProviderDetailSection(title: "Muse Code subscription", rows: [
                .init(label: "Plan", value: "Muse Code Power Usage"),
                .init(label: "5 hours", value: "96%"),
                .init(label: "Weekly", value: "40%"),
            ])],
            updatedAt: after.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .muse,
                accountEmail: "ada@example.com",
                accountOrganization: nil,
                loginMethod: "Muse Code Power Usage"),
            dataConfidence: .exact)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot) in [("before-swift", before), ("after-plugin", after)] {
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: .muse,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[.muse]),
                    snapshot: snapshot,
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: nil,
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .muse)),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: true,
                    resetTimeDisplayStyle: .absolute,
                    tokenCostUsageEnabled: false,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: true,
                    usesLiveSubtitle: false,
                    now: Date(timeIntervalSince1970: 1_788_580_000)))
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("muse-\(name).png"))
            }
        }
    }
}

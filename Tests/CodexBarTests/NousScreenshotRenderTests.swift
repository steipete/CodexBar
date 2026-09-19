import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class NousScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticPluginCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_NOUS_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_NOUS_SCREENSHOT_DIR to render synthetic Nous cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let full = try await NousPluginTests.fetch(NousPluginTests.account, engine: .quickJS)
        let partial = try await NousPluginTests.fetch(
            #"{"subscription":{"plan":"Ultra","monthly_credits":220}}"#,
            engine: .quickJS)
        // Golden output of #3376's original Swift parser for that same partial payload.
        let before = try UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            details: [
                ProviderDetailSection(title: "Subscription", rows: [
                    .init(label: "Subscription credits", value: "$0.00 of $220.00 left"),
                ]),
                ProviderDetailSection(title: "Credits", rows: [
                    .init(label: "Top-up credits", value: "$0.00"),
                ]),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .nous, accountEmail: nil, accountOrganization: nil, loginMethod: "Ultra"),
            dataConfidence: .exact)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot) in [("before-partial", before), ("after-partial", partial), ("after-full", full)] {
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: .nous,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[.nous]),
                    snapshot: snapshot,
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: nil,
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .nous)),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: true,
                    resetTimeDisplayStyle: .absolute,
                    tokenCostUsageEnabled: false,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: true,
                    usesLiveSubtitle: false,
                    now: Date()))
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("nous-\(name).png"))
            }
        }
    }
}

import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class CodeRabbitScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticReportCards() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CODERABBIT_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CODERABBIT_SCREENSHOT_DIR to render synthetic CodeRabbit cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_789_700_000)
        let after = try CodeRabbitUsageParser.parse(usageText: """
        Organization :
        Usage billing : inactive
        Your reviews : 10
        Period resets : 2026-09-30
        """, now: now).toUsageSnapshot()
        // Golden output of the proposal's multiline regex and auth/plan projection.
        let before = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Billing", rows: [
                .init(label: "Reviews", value: "10"),
                .init(label: "Organization", value: "Usage billing : inactive"),
                .init(label: "Usage billing", value: "inactive"),
                .init(label: "Period resets", value: "2026-09-30"),
            ])],
            subscriptionRenewsAt: ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .coderabbit,
                accountEmail: nil,
                accountOrganization: "Usage billing : inactive",
                loginMethod: "10 reviews"))
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot) in [("before", before), ("after", after)] {
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: .coderabbit,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[.coderabbit]),
                    snapshot: snapshot,
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: nil,
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .coderabbit)),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: true,
                    resetTimeDisplayStyle: .absolute,
                    tokenCostUsageEnabled: false,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: true,
                    usesLiveSubtitle: false,
                    now: now))
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("coderabbit-\(name).png"))
            }
        }
    }
}

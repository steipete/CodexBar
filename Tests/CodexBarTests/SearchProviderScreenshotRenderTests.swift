import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class SearchProviderScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticSearchProviderCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SEARCH_PROVIDER_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SEARCH_PROVIDER_SCREENSHOT_DIR to render synthetic search provider cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tavily = try await TavilyPluginTests.fetch(engine: .quickJS)
        let linkup = try Self.balanceSnapshot(
            provider: .linkup, title: "Account balance", label: "Credit balance", value: "$123.46", loginMethod: "API")
        let tinyapi = try Self.balanceSnapshot(
            provider: .tinyapi,
            title: "Credits",
            label: "Available credits",
            value: "140 credits",
            loginMethod: "Browser session")
        let fixtures: [(UsageProvider, UsageSnapshot, [String])] = try [
            (.tavily, tavily, ["ACCOUNT PLAN", "API key", "PAY AS YOU GO", "500 credits", "1,000 credits"]),
            (.linkup, linkup, ["Credit balance", "$123.46"]),
            (.tinyapi, tinyapi, ["Available credits", "140"]),
            (.exa, Self.balanceSnapshot(
                provider: .exa,
                title: "API key this month (UTC)",
                label: "Spend",
                value: "$45.67",
                loginMethod: "Service key"), ["API KEY THIS MONTH (UTC)", "Spend", "$45.67"]),
        ]
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (provider, fixture, expectedText) in fixtures {
                // Before is the shared empty state, not a claim that main already supported this provider.
                for after in [false, true] {
                    let snapshot = after ? fixture : nil
                    let model = try UsageMenuCardView.Model.make(.init(
                        provider: provider,
                        metadata: XCTUnwrap(ProviderDefaults.metadata[provider]),
                        snapshot: snapshot,
                        credits: nil,
                        creditsError: nil,
                        dashboardError: nil,
                        tokenSnapshot: nil,
                        tokenError: nil,
                        account: AccountInfo(email: nil, plan: snapshot?.loginMethod(for: provider)),
                        isRefreshing: false,
                        lastError: nil,
                        usageBarsShowUsed: true,
                        resetTimeDisplayStyle: .absolute,
                        tokenCostUsageEnabled: false,
                        showOptionalCreditsAndExtraUsage: true,
                        hidePersonalInfo: true,
                        paceVisible: false,
                        usesLiveSubtitle: false,
                        now: fixture.updatedAt))
                    XCTAssertEqual(model.providerDetails.count, after ? fixture.details.count : 0)
                    if !after { XCTAssertTrue(model.metrics.isEmpty) }
                    for dark in [false, true] {
                        let view = try AnyView(UsageMenuCardView(model: model, width: 380)
                            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                            .environment(\.timeZone, XCTUnwrap(TimeZone(secondsFromGMT: 0)))
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.displayScale, 2)
                            .environment(\.accessibilityEnabled, true)
                            .background(Color(nsColor: .windowBackgroundColor)))
                        let hosting = NSHostingView(rootView: view)
                        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        let stem = "\(provider.rawValue)-\(after ? "after" : "before")-\(dark ? "dark" : "light")"
                        let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                        XCTAssertEqual(hosting.frame.width, 380)
                        XCTAssertFalse(png.isEmpty)
                        try png.write(to: directory.appendingPathComponent("\(stem).png"))
                        let accessibility = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
                        try accessibility.write(
                            to: directory.appendingPathComponent("\(stem)-accessibility.txt"),
                            atomically: true,
                            encoding: .utf8)
                        if after {
                            for text in expectedText {
                                XCTAssertTrue(accessibility.contains(text), "\(stem): missing \(text)")
                            }
                        }
                    }
                }
            }
        }
    }

    private static func balanceSnapshot(
        provider: UsageProvider,
        title: String,
        label: String,
        value: String,
        loginMethod: String) throws -> UsageSnapshot
    {
        try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: title, rows: [.init(label: label, value: value)])],
            updatedAt: Date(timeIntervalSince1970: 1_789_700_000),
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID, accountEmail: nil, accountOrganization: nil, loginMethod: loginMethod),
            dataConfidence: .exact)
    }
}

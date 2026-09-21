import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class AntigravityCostScreenshotTests: XCTestCase {
    func test_renderSyntheticLocalCostCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ANTIGRAVITY_COST_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ANTIGRAVITY_COST_SCREENSHOT_DIR for synthetic Antigravity cost proof")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [AntigravityLocalFixture.blob(
            model: "claude-sonnet-4-6",
            system: 0,
            input: 400_000,
            output: 50000,
            cacheRead: 100_000,
            reasoning: 0)])
        let after = try await fixture.snapshot()
        XCTAssertEqual(try XCTUnwrap(after.last30DaysCostUSD), 1.98, accuracy: 0.000001)
        let unpriced = try fixture.report().report.data
        let before = CostUsageTokenSnapshot(
            sessionTokens: 550_000,
            sessionCostUSD: nil,
            last30DaysTokens: 550_000,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            daily: unpriced,
            updatedAt: AntigravityLocalFixture.now)
        for (name, snapshot) in [("token-only", before), ("api-estimate", after)] {
            let model = try Self.model(snapshot)
            try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                let view = AnyView(UsageMenuCardView(model: model, width: 380)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("antigravity-\(name).png"))
            }
        }
        try await Self.showNativeProof(snapshot: after, directory: directory)
        // Let the signed production CLI read the same independently constructed local SQLite fixture.
        let cliHome = directory.appendingPathComponent("synthetic-home", isDirectory: true)
        try FileManager.default.createDirectory(at: cliHome, withIntermediateDirectories: true)
        let original = fixture.root.appendingPathComponent(".gemini", isDirectory: true)
        let destination = cliHome.appendingPathComponent(".gemini", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: original, to: destination)
        }
    }

    private static func showNativeProof(snapshot: CostUsageTokenSnapshot, directory: URL) async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_ANTIGRAVITY_NATIVE_PROOF"] == "1" else { return }
        let partial = CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            costProvenance: .listPriceEstimate,
            daily: snapshot.daily,
            updatedAt: snapshot.updatedAt)
        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .antigravity, displayName: "Synthetic Antigravity", snapshot: partial)],
            requestedDays: 3,
            now: AntigravityLocalFixture.now,
            calendar: AntigravityLocalFixture.calendar)
        let group = try XCTUnwrap(dashboard.groups.first)
        XCTAssertTrue(group.providers.allSatisfy(\.tokensAreLowerBound))
        XCTAssertTrue(group.dailySummaries.allSatisfy(\.hasPartialCounts))
        let card = try Self.model(snapshot)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires an isolated native test host") }
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1150, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Antigravity Cost Proof"
        window.isReleasedWhenClosed = false
        let done = directory.appendingPathComponent("native-done")
        window.contentView = NSHostingView(rootView: HStack(alignment: .top, spacing: 20) {
            UsageMenuCardView(model: card, width: 360).padding(12)
            ScrollViewReader { proxy in
                VStack {
                    HStack {
                        Text("Synthetic partial history").foregroundStyle(.secondary)
                        Spacer()
                        Button("Summary") { proxy.scrollTo("summary", anchor: .top) }
                        Button("Daily ledger") { proxy.scrollTo("ledger", anchor: .bottom) }
                        Button("Finish proof") {
                            FileManager.default.createFile(atPath: done.path, contents: Data())
                        }
                    }.padding(12)
                    ScrollView {
                        VStack {
                            Color.clear.frame(height: 1).id("summary")
                            SpendDashboardCurrencySection(group: group, requestedDays: 3, hidePersonalInfo: true)
                            Color.clear.frame(height: 1).id("ledger")
                        }.padding(20)
                    }
                }
            }
        }.environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, AntigravityLocalFixture.calendar.timeZone)
            .preferredColorScheme(.light))
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let receipt = ["pid": Int(ProcessInfo.processInfo.processIdentifier), "window": window.windowNumber]
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("native-state.json"))
        let deadline = Date().addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "Native proof did not finish")
    }

    private static func model(_ tokens: CostUsageTokenSnapshot) throws -> UsageMenuCardView.Model {
        let now = AntigravityLocalFixture.now
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        return try UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.antigravity]),
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokens,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: "Synthetic"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: now))
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
final class OpenRouterNativeProofTests: XCTestCase {
    func test_reportedReasoningReachesNativeViewsAndDashboardExport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_OPENROUTER_REASONING_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_OPENROUTER_REASONING_PROOF_DIR for synthetic native Activity proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = output.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              home.count > parent.count, home.starts(with: parent),
              let expected = environment["CODEXBAR_OPENROUTER_REASONING_EXPECT_HISTORY"],
              ["0", "1"].contains(expected)
        else { return XCTFail("Use a contained home, credential isolation, and explicit expected history state") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let snapshot = try await OpenRouterReasoningTestSupport.snapshot()
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.detailRow(label: "Remaining")?.value, "$60.00")
        XCTAssertEqual(snapshot.costUsage != nil, expected == "1")
        let inputs = snapshot.costUsage.map {
            [SpendDashboardModel.ProviderInput(provider: .openrouter, displayName: "OpenRouter", snapshot: $0)]
        } ?? []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let dashboard = SpendDashboardModel.build(
            inputs: inputs, requestedDays: 30, now: OpenRouterReasoningTestSupport.now, calendar: calendar)
        if expected == "1" {
            let group = try XCTUnwrap(dashboard.groups.first)
            XCTAssertEqual(group.totalTokens, 923)
            XCTAssertEqual(group.totalCost, 0.875)
            XCTAssertEqual(group.tokenMix.inputTokens, 523)
            XCTAssertEqual(group.tokenMix.outputTokens, 400)
            XCTAssertEqual(group.tokenMix.reasoningTokens, 441)
            XCTAssertEqual(group.modelHistoryCompleteness, .complete)
        } else {
            XCTAssertTrue(dashboard.groups.isEmpty)
            XCTAssertEqual(snapshot.detailRow(label: "Last 30 days")?.value, "Unavailable right now")
        }
        try SpendDashboardJSONExporter.encodedData(model: dashboard, hiddenSourceIDs: [])
            .write(to: output.appendingPathComponent("dashboard.json"))
        let cli = CLIRenderer.renderText(
            provider: .openrouter,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "OpenRouter — synthetic Activity", status: nil, useColor: false, resetStyle: .countdown),
            now: OpenRouterReasoningTestSupport.now)
        XCTAssertTrue(cli.contains("Balance: $60.00"))
        try cli.write(to: output.appendingPathComponent("cli.txt"), atomically: true, encoding: .utf8)
        let card = try Self.menuCard(snapshot)

        guard NSApplication.shared.delegate == nil else { return XCTFail("Use a standalone test host") }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let menu = AnyView(UsageMenuCardView(model: card, width: 420).padding(20).frame(width: 460))
            try Self.pngData(for: menu, appearance: appearance)
                .write(to: output.appendingPathComponent("menu-\(name).png"))
            if let group = dashboard.groups.first {
                let view = AnyView(SpendDashboardCurrencySection(
                    group: group, requestedDays: 30, hidePersonalInfo: true).padding(24).frame(width: 900))
                try Self.pngData(for: view, appearance: appearance)
                    .write(to: output.appendingPathComponent("dashboard-\(name).png"))
            }
        }
        try JSONSerialization.data(withJSONObject: [
            "syntheticOnly": true,
            "historyAvailable": snapshot.costUsage != nil,
            "totalTokens": (snapshot.costUsage?.last30DaysTokens).map { $0 as Any } ?? NSNull(),
            "reasoningTokens": (dashboard.groups.first?.tokenMix.reasoningTokens).map { $0 as Any } ?? NSNull(),
            "groupCount": dashboard.groups.count,
            "details": snapshot.details.flatMap(\.rows).map {
                ["label": $0.label, "value": $0.value, "secondaryValue": $0.secondaryValue ?? ""]
            },
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("state.json"))
    }

    func test_invalidActivityDiagnosticReachesNativeCardAndCLI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_OPENROUTER_DIAGNOSTIC_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_OPENROUTER_DIAGNOSTIC_PROOF_DIR for synthetic diagnostic proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = output.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              home.count > parent.count, home.starts(with: parent),
              let expected = environment["CODEXBAR_OPENROUTER_DIAGNOSTIC_EXPECT_REASON"],
              ["Request failed", "Response was invalid"].contains(expected)
        else { return XCTFail("Use a contained home, credential isolation, and explicit expected diagnostic") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshot = try await OpenRouterDiagnosticFixture.fetch(
            engine: .quickJS,
            endpoint: .history,
            result: .response(200, OpenRouterDiagnosticFixture.activity(model: String(repeating: "x", count: 65))))
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.detailRow(label: "Remaining")?.value, "$60.00")
        XCTAssertNil(snapshot.costUsage)
        XCTAssertEqual(snapshot.detailRow(label: "Last 30 days")?.secondaryValue, expected)
        let cli = CLIRenderer.renderText(
            provider: .openrouter,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "OpenRouter", status: nil, useColor: false, resetStyle: .countdown),
            now: OpenRouterReasoningTestSupport.now)
        XCTAssertTrue(cli.contains(expected))
        try cli.write(to: output.appendingPathComponent("cli.txt"), atomically: true, encoding: .utf8)
        let card = try Self.menuCard(snapshot)
        guard NSApplication.shared.delegate == nil else { return XCTFail("Use a standalone test host") }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let menu = AnyView(UsageMenuCardView(model: card, width: 420).padding(20).frame(width: 460))
            try Self.pngData(for: menu, appearance: appearance)
                .write(to: output.appendingPathComponent("menu-\(name).png"))
        }
        try JSONEncoder().encode(snapshot).write(to: output.appendingPathComponent("snapshot.json"))
    }

    private static func menuCard(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.openrouter]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot.costUsage,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            preferredCurrencyCode: "USD",
            now: OpenRouterReasoningTestSupport.now))
    }

    private static func pngData(for view: AnyView, appearance: NSAppearance.Name) throws -> Data {
        let hosting = NSHostingView(rootView: view
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, .gmt)
            .preferredColorScheme(appearance == .aqua ? .light : .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

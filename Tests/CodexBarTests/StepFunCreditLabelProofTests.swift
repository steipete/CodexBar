import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
final class StepFunCreditLabelProofTests: XCTestCase {
    func test_creditLabelsInProductionMenuAndCLI() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_STEPFUN_LABEL_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_STEPFUN_LABEL_PROOF_DIR for signed synthetic rendering")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              NSHomeDirectory().hasPrefix(output.deletingLastPathComponent().path + "/")
        else { return XCTFail("Use a contained home and credential/session isolation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let baseline = environment["CODEXBAR_STEPFUN_LABEL_PROOF_BASELINE"] == "1"
        let payloads = [
            """
            {"status":1,"plan_family":2,"plan_credit_rate_limit":{
              "subscription_credit_left_rate":0.25,"subscription_credit_reset_time":"1790812800"}}
            """,
            """
            {"status":1,"plan_family":2,"plan_credit_rate_limit":{"topup_credit_left_rate":0.6}}
            """,
            """
            {"status":1,"five_hour_usage_left_rate":0.7,"five_hour_usage_reset_time":"1790812800",
              "weekly_usage_left_rate":0.8,"weekly_usage_reset_time":"1790899200"}
            """,
        ]
        let titles = ["Monthly credit", "Credit without a reset", "Coding Plan (unchanged)"]
        let snapshots = try payloads.map {
            try StepFunUsageFetcher._parseSnapshotForTesting(Data($0.utf8)).toUsageSnapshot()
        }
        XCTAssertNil(snapshots[1].primary?.windowMinutes)
        if !baseline {
            XCTAssertNil(snapshots[1].primary?.resetsAt)
            XCTAssertNil(snapshots[1].primary?.resetDescription)
        }
        XCTAssertEqual(snapshots[2].primary?.windowMinutes, 300)
        XCTAssertEqual(snapshots[2].secondary?.windowMinutes, 10080)
        let models = try snapshots.enumerated().map { index, snapshot in
            let model = try UsageMenuCardView.Model.make(.init(
                provider: .stepfun,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.stepfun]),
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
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                paceVisible: false,
                usesLiveSubtitle: false,
                now: snapshot.updatedAt))
            let label = baseline || index == 2 ? "5h Window" : "Credit"
            XCTAssertEqual(model.metrics.first { $0.id == "primary" }?.title, label)
            let cli = CLIRenderer.renderText(
                provider: .stepfun,
                snapshot: snapshot,
                credits: nil,
                context: RenderContext(header: "StepFun", status: nil, useColor: false, resetStyle: .absolute),
                now: snapshot.updatedAt)
            XCTAssertTrue(cli.contains("\(label):"))
            if !baseline, index == 1 { XCTAssertFalse(cli.contains("Resets")) }
            try cli.write(to: output.appendingPathComponent("case-\(index)-cli.txt"), atomically: true, encoding: .utf8)
            return model
        }
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 18) {
                Text(baseline ? "Before: credit balances use a time-window label" : "After: credit balances say Credit")
                    .font(.title2.bold())
                Text("Synthetic responses · Production parser, menu cards, and CLI renderer")
                    .font(.caption)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(models.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(titles[index]).font(.headline)
                            UsageMenuCardView(model: models[index], width: 320)
                        }
                    }
                }
            }
            .padding(24)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.displayScale, 2)
            .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                .write(to: output.appendingPathComponent("\(dark ? "dark" : "light").png"))
        }
    }
}

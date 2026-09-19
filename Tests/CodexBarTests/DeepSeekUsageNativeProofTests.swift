import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class DeepSeekUsageNativeProofTests: XCTestCase {
    func test_fixtureUsageCards() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_DEEPSEEK_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_DEEPSEEK_PROOF_DIR for signed synthetic proof")
        }
        guard SettingsStore.isRunningTests,
              env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
        else { return XCTFail("Use isolated fixtures") }
        let output = URL(
            fileURLWithPath: path,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_779_796_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let time = Int(now.timeIntervalSince1970)
        let amount = Data("""
        {"code":0,"data":{"biz_data":{"series":[{"api_key":{"tracking_id":"synthetic-key"},
        "model":"example-model","buckets":[{"time":\(time),"usage":{"RESPONSE_TOKEN":1250,"REQUEST":4}}]}]}}}
        """.utf8)
        let cost = Data("""
        {"code":0,"data":{"biz_data":{"data":[{"currency":"USD","series":[{
        "api_key":{"tracking_id":"synthetic-key"},"model":"example-model",
        "buckets":[{"time":\(time),"cost":"0.12"}]}]}]}}}
        """.utf8)
        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            now: now,
            calendar: calendar,
            transport: ProviderHTTPTransportHandler { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertTrue(url.path.contains("by_api_key"))
                return try (
                    url.path.hasSuffix("amount") ? amount : cost,
                    XCTUnwrap(HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil)))
            })
        XCTAssertEqual(summary.period, .last30Days)
        XCTAssertEqual(summary.todayTokens, 1250)
        XCTAssertEqual(summary.modelCosts, [DeepSeekModelCost(model: "example-model", cost: 0.12)])
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 9.32,
            grantedBalance: 1,
            toppedUpBalance: 8.32,
            usageSummary: summary,
            updatedAt: now).toUsageSnapshot()
        let before = snapshot.with(details: snapshot.details.map { section in
            section.title == "Spend"
                ? .makeSection(title: section.title, rows: [], chart: section.chart)
                : section
        })
        for (stage, usage) in [("before", before), ("after", snapshot)] {
            let model = try UsageMenuCardView.Model.make(.init(
                provider: .deepseek,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.deepseek]),
                snapshot: usage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                now: now))
            for dark in [false, true] {
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: output.appendingPathComponent("\(stage)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

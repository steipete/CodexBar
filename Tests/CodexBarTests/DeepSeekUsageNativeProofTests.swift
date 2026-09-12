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
        var models: [UsageMenuCardView.Model] = []
        for usage in [summary, nil] {
            let snapshot = DeepSeekUsageSnapshot(
                isAvailable: true,
                currency: "USD",
                totalBalance: 9.32,
                grantedBalance: 1,
                toppedUpBalance: 8.32,
                usageSummary: usage,
                updatedAt: now).toUsageSnapshot()
            try models.append(UsageMenuCardView.Model.make(.init(
                provider: .deepseek,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.deepseek]),
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(
                    email: nil,
                    plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                now: now)))
        }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let oldPolicy = app.activationPolicy()
        let previous = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic DeepSeek Usage"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HStack(
            alignment: .top,
            spacing: 24)
        {
            ForEach(
                models.indices,
                id: \.self)
            { index in
                VStack(alignment: .leading) {
                    Text(index == 0 ? "Daily endpoint fixture" : "API-key balance only").font(.headline)
                    UsageMenuCardView(
                        model: models[index],
                        width: 350)
                }
            }
        }.padding(24))
        defer { window.close(); _ = app.setActivationPolicy(oldPolicy); previous?.activate() }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try JSONSerialization.data(withJSONObject: [
            "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
            "todayTokens": summary.todayTokens, "todayCost": XCTUnwrap(summary.todayCost),
        ]).write(to: output.appendingPathComponent("state.json"))
        let deadline = Date().addingTimeInterval(600)
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path), Date() < deadline {
            if let event = app.nextEvent(
                matching: .any,
                until: Date().addingTimeInterval(0.02),
                inMode: .default,
                dequeue: true)
            {
                app.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClaudeCloudCreditsPublicationTests {
    private static let payload = Data(#"""
    {"five_hour":{"utilization":12},"seven_day":{"utilization":34},
     "extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":500},
     "iguana_necktie":{"limit_dollars":100,"used_dollars":25,"remaining_dollars":75,
                       "resets_at":"2099-11-05T07:59:00Z","locked_reason":null}}
    """#.utf8)

    @Test
    func `OAuth publishes cloud dollars separately from quota and spend`() throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.payload)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.secondary?.usedPercent == 34)
        #expect(snapshot.providerCost?.used == 5)
        #expect(snapshot.providerCost?.limit == 20)
        let row = try #require(snapshot.details.first { $0.title == "Cloud credits" }?.rows.first)
        #expect(row.label == "Cloud credits")
        #expect(row.usageValue == 75)
        #expect(row.progress?.used == 25)
        #expect(row.progress?.total == 100)
    }

    @MainActor
    @Test
    func `menu exposes cloud credits as an independently visible balance`() throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.payload)
        let model = try Self.menuModel(ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage))
        #expect(model.usageItemDescriptors.contains {
            $0.id == .detailSection("Cloud credits") && $0.title == "Cloud credits"
        })
    }

    @Test
    func `cloud balances never change CLI quota pacing`() throws {
        let now = Date(timeIntervalSince1970: 1_790_812_800)
        var object = try #require(JSONSerialization.jsonObject(with: Self.payload) as? [String: Any])
        object["seven_day"] = ["utilization": 34, "resets_at": now.addingTimeInterval(3 * 86400).ISO8601Format()]
        var snapshots: [UsageSnapshot] = []
        for _ in 0..<2 {
            let data = try JSONSerialization.data(withJSONObject: object)
            let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
            snapshots.append(ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage))
            object.removeValue(forKey: "iguana_necktie")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pace = try snapshots.map {
            try encoder.encode(#require(CLIRenderer.providerPacePayload(provider: .claude, snapshot: $0, now: now)))
        }
        #expect(pace[0] == pace[1])
        #expect(snapshots[0].primary == snapshots[1].primary)
        #expect(snapshots[0].secondary == snapshots[1].secondary)
        #expect(snapshots[0].extraRateWindows == snapshots[1].extraRateWindows)
    }

    @MainActor
    @Test
    func `render synthetic before and after cloud balances when requested`() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_CLOUD_CREDITS_PROOF_DIR"] else { return }
        try #require(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        try #require(environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var object = try #require(JSONSerialization.jsonObject(with: Self.payload) as? [String: Any])
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for phase in ["after", "before"] {
                let usage = try ClaudeUsageFetcher
                    ._mapOAuthUsageForTesting(JSONSerialization.data(withJSONObject: object))
                let model = try Self.menuModel(ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage))
                let view = VStack(alignment: .leading, spacing: 12) {
                    Text("Synthetic \(phase == "before" ? "baseline" : "cloud credits")").font(.caption)
                    UsageMenuCardView(model: model, width: 320)
                }
                .padding(16)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("claude-cloud-credits-\(phase).png"))
                // Reconstruct main's omission without changing quotas or Extra usage.
                object.removeValue(forKey: "iguana_necktie")
            }
        }
    }

    private static func menuModel(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: snapshot,
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
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            usesLiveSubtitle: false,
            now: snapshot.updatedAt))
    }
}

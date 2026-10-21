import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeSubscriptionPresentationTests {
    private func model(_ snapshot: UsageSnapshot, plan: String = "Claude Pro") throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: plan),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: snapshot.updatedAt))
    }

    private var snapshot: UsageSnapshot {
        UsageSnapshot(
            primary: .init(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test(arguments: ["Claude Pro", "Claude Max", "Claude Team", "Claude Enterprise"])
    func `plan labels never invent missing billing dates`(_ plan: String) throws {
        #expect(try self.model(self.snapshot, plan: plan).usageNotes.isEmpty)
        #expect(UsageMenuCardView.Model.subscriptionMetadataNotes(snapshot: nil, provider: .claude).isEmpty)
    }

    @Test func `calendar only date uses its original day in the shared row`() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        let expiry = self.snapshot.withSubscriptionMetadata(expiresAt: date, renewsAt: nil, expiresAtIsDateOnly: true)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        #expect(try self.model(expiry).usageNotes == ["Plan expires: \(formatter.string(from: date))"])
        let renewal = self.snapshot.withSubscriptionMetadata(expiresAt: nil, renewsAt: date, renewsAtIsDateOnly: true)
        #expect(try self.model(renewal).usageNotes == ["Plan renews: \(formatter.string(from: date))"])
        #expect(UsageMenuCardView.Model.subscriptionMetadataNotes(snapshot: self.snapshot, provider: .codex).isEmpty)
    }

    @Test func `render synthetic before and after production cards when requested`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_SUBSCRIPTION_PROOF_DIR"]
        else { return }
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        let cases = [
            ("before", self.snapshot),
            (
                "renewal",
                self.snapshot.withSubscriptionMetadata(expiresAt: nil, renewsAt: date, renewsAtIsDateOnly: true)),
            (
                "expiration",
                self.snapshot.withSubscriptionMetadata(expiresAt: date, renewsAt: nil, expiresAtIsDateOnly: true)),
        ]
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, snapshot) in cases {
            let model = try self.model(snapshot)
            let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 16) {
                Text("Synthetic Claude billing · \(name)").font(.caption)
                UsageMenuCardView(model: model, width: 340)
            }.padding(20).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("claude-billing-\(name).png"))
        }
    }
}

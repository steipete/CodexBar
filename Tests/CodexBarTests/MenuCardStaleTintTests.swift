import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuCardStaleTintTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func model(lastError: String?) throws -> UsageMenuCardView.Model {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 34,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 61,
                windowMinutes: 10080,
                resetsAt: Self.now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Self.now.addingTimeInterval(-7200))
        return try UsageMenuCardView.Model.make(.init(
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
            lastError: lastError,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: Self.now))
    }

    @Test
    func `failed refresh tints retained bars neutral`() throws {
        let model = try self.model(lastError: "Claude Code credentials changed.")
        #expect(model.subtitleStyle == .error)
        #expect(!model.metrics.isEmpty)
        #expect(model.progressColor == UsageMenuCardView.Model.staleProgressColor)
    }

    @Test
    func `successful refresh keeps the provider tint`() throws {
        let model = try self.model(lastError: nil)
        #expect(model.subtitleStyle == .info)
        #expect(model.progressColor == UsageMenuCardView.Model.progressColor(for: .claude))
    }
}

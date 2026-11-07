import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuCardLowQuotaTintTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func model(
        primaryUsed: Double,
        showUsed: Bool,
        quotaRefreshFailed: Bool = false) throws -> UsageMenuCardView.Model
    {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: primaryUsed,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 61,
                windowMinutes: 10080,
                resetsAt: Self.now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Self.now.addingTimeInterval(quotaRefreshFailed ? -7200 : 0))
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
            lastError: quotaRefreshFailed ? "Synthetic quota refresh failure" : nil,
            quotaRefreshFailed: quotaRefreshFailed,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: Self.now))
    }

    private func tints(_ model: UsageMenuCardView.Model) -> [Color] {
        model.metrics.prefix(2).map { metric in
            MetricRow(
                metric: metric,
                layoutMetric: metric,
                title: metric.title,
                progressColor: model.progressColor,
                isRetainedMeasurement: model.showsRetainedMeasurement).barTint
        }
    }

    @Test(arguments: [true, false])
    func `a window with at most ten percent left uses the low-quota tint`(showUsed: Bool) throws {
        for used in [90.0, 95, 100] {
            let model = try self.model(primaryUsed: used, showUsed: showUsed)
            #expect(self.tints(model) == [Color(nsColor: .systemRed), model.progressColor])
        }
    }

    @Test(arguments: [true, false])
    func `healthy windows keep the provider tint`(showUsed: Bool) throws {
        for used in [0.0, 50, 89] {
            let model = try self.model(primaryUsed: used, showUsed: showUsed)
            #expect(self.tints(model) == [model.progressColor, model.progressColor])
        }
    }

    @Test
    func `retained measurements stay neutral even when low`() throws {
        let model = try self.model(primaryUsed: 97, showUsed: true, quotaRefreshFailed: true)
        #expect(model.showsRetainedMeasurement)
        #expect(self.tints(model).first == UsageMenuCardView.Model.staleProgressColor)
    }
}

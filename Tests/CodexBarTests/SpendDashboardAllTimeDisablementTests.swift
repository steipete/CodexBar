import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardAllTimeDisablementTests {
    @Test(arguments: [false, true])
    func `ledger rows clear immediately when tracking or every provider is disabled`(
        disableTracking: Bool) async throws
    {
        let defaultsSuite = "SpendDashboardAllTimeDisablementTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardAllTimeDisablementTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let enabled = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            codexAccountIdentities: [],
            sourceOwnershipFingerprints: ["claude:test-owner"])
        let input = Self.input()
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { mode in Self.request(configuration: enabled, force: mode.forcesLoader) },
            loader: { _ in SpendDashboardLoadResult(inputs: [input], failedSourceIDs: []) },
            historyLedger: SpendHistoryLedger(fileURL: fileURL))

        controller.update(configuration: enabled)
        await Self.waitUntil { !controller.isRefreshing }
        controller.selectRange(.allTime)
        await Self.waitUntil { controller.model.groups.first?.totalCost == 4 }
        #expect(controller.model.groups.first?.totalCost == 4)

        controller.update(configuration: SpendDashboardConfiguration(
            costUsageEnabled: !disableTracking,
            providerIDs: disableTracking ? enabled.providerIDs : [],
            codexAccountIdentities: [],
            sourceOwnershipFingerprints: []))

        #expect(!controller.isRefreshing)
        #expect(controller.model.groups.isEmpty)
    }

    private static func request(
        configuration: SpendDashboardConfiguration,
        force: Bool) -> SpendDashboardLoadRequest
    {
        SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: self.fixtureNow,
            force: force)
    }

    private static func input() -> SpendDashboardModel.ProviderInput {
        SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 10,
                last30DaysCostUSD: 4,
                currencyCode: "USD",
                historyDays: 1,
                historyCoverageIsEstablished: true,
                daily: [CostUsageDailyReport.Entry(
                    date: "2026-07-15",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 10,
                    costUSD: 4,
                    modelsUsed: nil,
                    modelBreakdowns: nil)],
                updatedAt: self.fixtureNow))
    }

    /// Noon UTC stays on July 15 in both CI's UTC zone and the local Pacific zone.
    private static let fixtureNow = Date(timeIntervalSince1970: 1_784_116_800)

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for controller state")
    }
}

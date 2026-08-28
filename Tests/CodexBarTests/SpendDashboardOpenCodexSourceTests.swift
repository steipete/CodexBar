import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardOpenCodexSourceTests {
    @Test
    func `OpenCodex publication distinguishes unavailable and confirmed empty`() {
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [],
            codexAccountIdentities: [],
            openCodexUsageLogsEnabled: true)
        let request = SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: Date(timeIntervalSince1970: 1_787_079_600),
            force: false)

        let unavailable = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            [],
            request: request,
            environment: ["TESTING_LIBRARY_VERSION": "1"])
        #expect(unavailable.observation == .unavailable)

        let confirmedEmpty = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            [],
            request: request,
            environment: ["OPENCODEX_HOME": "/tmp/opencodex-publication-test"],
            entryLoader: { _ in [] })
        #expect(confirmedEmpty.observation == .confirmedEmpty)

        let failed = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            [],
            request: request,
            environment: ["OPENCODEX_HOME": "/tmp/opencodex-publication-test"],
            entryLoader: { _ in throw CocoaError(.fileReadCorruptFile) })
        #expect(failed.observation == .unavailable)
    }

    @Test
    func `OpenCodex-only configuration still starts a dashboard load`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = SpendDashboardControllerTests.controller(gate: gate)
        controller.update(configuration: SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [],
            openCodexUsageLogsEnabled: true))
        await SpendDashboardControllerTests.waitForPendingCount(1, gate: gate)
        #expect(controller.isRefreshing)
        await gate.resume(at: 0, result: .init(inputs: [
            SpendDashboardModel.ProviderInput(
                provider: .codex,
                displayName: "Codex",
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: 0,
                    sessionCostUSD: 0,
                    last30DaysTokens: 12,
                    last30DaysCostUSD: 1,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-07-16",
                            inputTokens: 10,
                            outputTokens: 2,
                            totalTokens: 12,
                            costUSD: 1,
                            modelsUsed: nil,
                            modelBreakdowns: nil),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_784_179_200))),
        ], failedSourceIDs: []))
        await SpendDashboardControllerTests.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.providers.contains { $0.provider == .codex } == true)
        #expect(controller.model.groups.first?.providers
            .contains { $0.id == SpendDashboardModel.openCodexSourceID } == false)
    }

    @Test
    func `empty OpenCodex snapshots are not treated as a present source`() {
        let empty = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
        #expect(!SpendDashboardSource.shouldPublishOpenCodexSnapshot(empty))
        let populated = CostUsageTokenSnapshot(
            sessionTokens: 12,
            sessionCostUSD: 1,
            last30DaysTokens: 12,
            last30DaysCostUSD: 1,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-16",
                    inputTokens: 10,
                    outputTokens: 2,
                    totalTokens: 12,
                    costUSD: 1,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
        #expect(SpendDashboardSource.shouldPublishOpenCodexSnapshot(populated))
    }
}

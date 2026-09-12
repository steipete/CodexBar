import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardLocalHistoryTests {
    @Test
    func `local Pi history stays out of the subscription denominator`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 7,
            currencyCode: "USD",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-15",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 10,
                    costUSD: 7,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        let piInput = SpendDashboardModel.ProviderInput(
            id: UsageProvider.pi.rawValue,
            provider: .pi,
            displayName: "Pi",
            snapshot: snapshot,
            sourceKind: .localHistory)
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: now,
            isRefreshing: false,
            inputs: [piInput],
            sources: [
                SpendSourcePublication(
                    id: UsageProvider.pi.rawValue,
                    provider: .pi,
                    displayName: "Pi",
                    role: .localHistory,
                    state: .available),
            ])

        let model = publication.model(
            requestedDays: 30,
            now: now,
            calendar: calendar,
            preferredCurrencyCode: "USD",
            providerScope: [.pi])
        let summary = OverviewSpendSummary(
            model: model,
            providerCount: publication.subscriptionCount(providerScope: [.pi]),
            knownCostProviderCount: publication.knownCostSubscriptionCount(model: model, providerScope: [.pi]),
            knownTokenProviderCount: publication.knownTokenSubscriptionCount(model: model, providerScope: [.pi]))

        #expect(model.groups.first?.providers.first?.sourceKind == .localHistory)
        #expect(publication.subscriptionCount(providerScope: [.pi]) == 0)
        #expect(summary.providerCoverageText == "0 of 0 subscriptions have spend")
        #expect(summary.primarySpendText == "$7.00")
        #expect(!summary.isPartial)
    }

    @Test
    func `Pi keeps local history role without a loaded snapshot`() async throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let sourceID = UsageProvider.pi.rawValue
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [sourceID],
            codexAccountIdentities: [])

        for state in [SpendSourcePublication.State.unavailable, .confirmedEmpty] {
            let suiteName = "SpendDashboardLocalHistoryTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            let unavailableSourceIDs: Set<String> = state == .unavailable ? [sourceID] : []
            let confirmedEmptySourceIDs: Set<String> = state == .confirmedEmpty ? [sourceID] : []
            let controller = SpendDashboardController(
                userDefaults: defaults,
                requestBuilder: { mode in
                    SpendDashboardLoadRequest(
                        configuration: configuration,
                        capturedInputs: [],
                        unavailableSourceIDs: unavailableSourceIDs,
                        confirmedEmptySourceIDs: confirmedEmptySourceIDs,
                        codexRequests: [],
                        now: now,
                        force: mode.forcesLoader)
                },
                loader: { request in
                    SpendDashboardLoadResult(inputs: [], failedSourceIDs: request.unavailableSourceIDs)
                },
                nowProvider: { now })

            controller.update(configuration: configuration)
            #expect(controller.publication.sources.first?.role == .localHistory)
            try await SpendDashboardStateWait.until { !controller.isRefreshing }
            let source = try #require(controller.publication.sources.first)
            #expect(source.provider == .pi)
            #expect(source.role == .localHistory)
            #expect(source.state == state)
            #expect(controller.publication.subscriptionCount(providerScope: [.pi]) == 0)
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

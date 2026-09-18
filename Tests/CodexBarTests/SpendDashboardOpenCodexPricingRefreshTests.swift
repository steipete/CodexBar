import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardOpenCodexPricingRefreshTests {
    @Test
    func `fresh OpenCodex load refreshes pricing once with loaded entries before publication`() async throws {
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let entry = OpenCodexUsageEntry(
            requestID: "request-1",
            timestamp: now,
            provider: "openai",
            model: "gpt-5.4",
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12),
            totalTokens: 12)
        let recorder = PricingRefreshRecorder()

        let result = await SpendDashboardSource.mergingOpenCodexInputsAfterRefreshingPricing(
            [],
            request: Self.request(now: now),
            environment: Self.environment,
            entryLoader: { _ in [entry] },
            pricingRefresher: { entries, refreshDate in
                await recorder.record(entries: entries, now: refreshDate)
            })

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.entries == [entry])
        #expect(calls.first?.now == now)
        #expect(result.observation == .available)
        let published = try #require(result.inputs.first)
        #expect(published.provider == .codex)
        #expect(published.snapshot.last30DaysTokens == 12)
    }

    @Test
    func `OpenCodex guards do not refresh pricing`() async {
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let recorder = PricingRefreshRecorder()
        let refresher: @Sendable ([OpenCodexUsageEntry], Date) async -> Void = { entries, refreshDate in
            await recorder.record(entries: entries, now: refreshDate)
        }

        let disabled = await SpendDashboardSource.mergingOpenCodexInputsAfterRefreshingPricing(
            [],
            request: Self.request(now: now, enabled: false),
            environment: Self.environment,
            entryLoader: { _ in [] },
            pricingRefresher: refresher)
        let hidden = await SpendDashboardSource.mergingOpenCodexInputsAfterRefreshingPricing(
            [],
            request: Self.request(now: now, hidden: true),
            environment: Self.environment,
            entryLoader: { _ in [] },
            pricingRefresher: refresher)
        let empty = await SpendDashboardSource.mergingOpenCodexInputsAfterRefreshingPricing(
            [],
            request: Self.request(now: now),
            environment: Self.environment,
            entryLoader: { _ in [] },
            pricingRefresher: refresher)

        #expect(disabled.observation == .disabled)
        #expect(hidden.observation == .disabled)
        #expect(empty.observation == .confirmedEmpty)
        let calls = await recorder.calls
        #expect(calls.isEmpty)
    }

    private static let environment = ["OPENCODEX_HOME": "/tmp/opencodex-pricing-refresh-tests"]

    private static func request(
        now: Date,
        enabled: Bool = true,
        hidden: Bool = false) -> SpendDashboardLoadRequest
    {
        SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [],
                codexAccountIdentities: [],
                openCodexUsageLogsEnabled: enabled,
                hiddenSourceIDs: hidden ? [SpendDashboardModel.openCodexSourceID] : []),
            capturedInputs: [],
            unavailableSourceIDs: [],
            confirmedEmptySourceIDs: [],
            codexRequests: [],
            now: now,
            force: false)
    }
}

private actor PricingRefreshRecorder {
    struct Call: Sendable {
        let entries: [OpenCodexUsageEntry]
        let now: Date
    }

    private(set) var calls: [Call] = []

    func record(entries: [OpenCodexUsageEntry], now: Date) {
        self.calls.append(Call(entries: entries, now: now))
    }
}

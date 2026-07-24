import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardClockRolloverTests {
    @Test
    func `reporting window advances and rescans source inputs`() async throws {
        let loadedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let afterRollover = try #require(ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z"))
        let loadCount = LockIsolated(0)
        let clock = LockIsolated(loadedAt)
        let configuration = Self.configuration
        let initialInput = Self.input(day: "2026-07-15", cost: 4, updatedAt: loadedAt)
        let rolloverInput = Self.input(day: "2026-07-22", cost: 6, updatedAt: afterRollover)
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: clock.value,
                    force: mode.forcesLoader)
            },
            loader: { _ in
                let count = loadCount.value + 1
                loadCount.setValue(count)
                return SpendDashboardLoadResult(
                    inputs: [count == 1 ? initialInput : rolloverInput],
                    failedSourceIDs: [])
            },
            nowProvider: { clock.value })

        controller.update(configuration: configuration)
        await Self.waitUntil { !controller.isRefreshing }
        controller.selectDays(7)
        #expect(controller.model.groups.first?.totalCost == 4)
        let generation = controller.generation

        clock.setValue(afterRollover)
        controller.refreshDateWindow()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.generation == generation + 1)
        #expect(loadCount.value == 2)
        #expect(controller.model.groups.first?.totalCost == 6)
        #expect(controller.model.groups.first?.dailyPoints.count == 1)
    }

    @Test
    func `rollover replaces an in flight load instead of dropping the rescan`() async throws {
        let loadedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let afterRollover = try #require(ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z"))
        let clock = LockIsolated(loadedAt)
        let configuration = Self.configuration
        let staleInput = Self.input(day: "2026-07-15", cost: 4, updatedAt: loadedAt)
        let freshInput = Self.input(day: "2026-07-22", cost: 6, updatedAt: afterRollover)
        let gate = SpendDashboardRolloverGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: clock.value,
                    force: mode.forcesLoader)
            },
            loader: { request in
                await gate.load(request)
            },
            nowProvider: { clock.value })

        controller.update(configuration: configuration)
        await Self.waitForPendingCount(1, gate: gate)

        clock.setValue(afterRollover)
        controller.refreshDateWindow()
        await Self.waitForPendingCount(2, gate: gate)

        await gate.resume(at: 0, result: .init(inputs: [staleInput], failedSourceIDs: []))
        await gate.resume(at: 1, result: .init(inputs: [freshInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 6)
        #expect(controller.model.groups.first?.dailyPoints.count == 1)
    }

    private static let configuration = SpendDashboardConfiguration(
        costUsageEnabled: true,
        providerIDs: [UsageProvider.codex.rawValue],
        codexAccountIdentities: ["rollover"])

    private static func input(day: String, cost: Double, updatedAt: Date) -> SpendDashboardModel.ProviderInput {
        let entry = CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [entry],
            updatedAt: updatedAt)
        return SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: snapshot)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for controller state")
    }

    private static func waitForPendingCount(_ count: Int, gate: SpendDashboardRolloverGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) pending loads")
    }
}

private actor SpendDashboardRolloverGate {
    private struct Pending {
        let continuation: CheckedContinuation<SpendDashboardLoadResult, Never>
    }

    private var pending: [Pending] = []

    var pendingCount: Int {
        self.pending.count
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        _ = request
        return await withCheckedContinuation { continuation in
            self.pending.append(Pending(continuation: continuation))
        }
    }

    func resume(at index: Int, result: SpendDashboardLoadResult) {
        self.pending[index].continuation.resume(returning: result)
    }
}

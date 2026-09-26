import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CodexSSHCostWindowTests {
    @Test(arguments: [UsageProvider.codex, .claude])
    func `only Codex offers an SSH report even without a local snapshot`(provider: UsageProvider) {
        let settings = testSettingsStore(
            suiteName: "CodexSSHCostWindowTests-menu",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
        store.accountInfoCache[provider.instanceID] = UsageStore.AccountInfoCacheEntry(
            account: AccountInfo(email: nil, plan: nil),
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let menu = MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            versionText: "")
        let actions = menu.sections.flatMap(\.entries).compactMap { entry -> MenuDescriptor.MenuAction? in
            guard case let .action(_, action) = entry else { return nil }
            return action
        }
        #expect(actions.contains(.openCodexSSHCostReport) == (provider == .codex))
        #expect(MenuDescriptor.MenuAction.openCodexSSHCostReport.systemImageName == "network")
        #expect(!settings.costUsageEnabled)
    }

    @Test
    func `opening a report and rejecting an invalid host do not read either source`() async throws {
        let calls = Calls()
        let summary = try Self.summary()
        let query = CodexSSHCostQuery(
            local: { _ in await calls.record("local"); return summary },
            remote: { _, _ in await calls.record("remote"); return summary })
        #expect(!query.isRunning)
        #expect(query.reports.isEmpty)
        #expect(await calls.values.isEmpty)

        query.setHost("-oProxyCommand=bad")
        #expect(!query.canRefresh)
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()
        #expect(await calls.values.isEmpty)
        #expect(query.message == RemoteCodexCostError.invalidHost.localizedDescription)
    }

    @Test(arguments: [false, true], [false, true])
    func `each source keeps its own success or safe failure`(localFails: Bool, remoteFails: Bool) async throws {
        let calls = Calls()
        let local = try Self.summary(cost: 1.25)
        let remote = try Self.summary(cost: 2.5, updatedAt: "2026-05-01T08:00:00Z", timeZone: "GMT")
        let query = CodexSSHCostQuery(
            local: { _ in
                await calls.record("local")
                if localFails { throw FixtureError.privatePath }
                return local
            },
            remote: { host, _ in
                await calls.record(host)
                if remoteFails { throw FixtureError.privatePath }
                return remote
            })
        query.setHost("  research-server  ")
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()

        #expect(await calls.values == ["local", "research-server"])
        #expect(query.reports.count == 2)
        #expect(query.reports[0].source == "local")
        #expect(query.reports[1].host == "research-server")
        #expect(query.reports[0].history?.dailySummary == (localFails ? nil : local))
        #expect(query.reports[1].history?.dailySummary == (remoteFails ? nil : remote))
        #expect(query.reports[0].error == (localFails ? "Local Codex cost history is unavailable." : nil))
        #expect(query.reports[1].error == (remoteFails ? CodexSSHCostQuery.remoteDailyUnavailable : nil))
        #expect(!query.isRunning)
        query.setHost("other-server")
        #expect(query.reports.isEmpty)
    }

    @Test(arguments: [false, true])
    func `cancel drains the current task and discards even an uncancellable late result`(
        clearResults: Bool) async throws
    {
        let summary = try Self.summary()
        let gate = Gate()
        let calls = Calls()
        let query = CodexSSHCostQuery(
            local: { _ in summary },
            remote: { _, _ in
                await calls.record("remote")
                return await gate.load()
            })
        query.setHost("first-server")
        query.refresh(calendar: Self.calendar)
        await gate.waitUntilStarted()
        #expect(query.reports.first?.history?.dailySummary == summary)
        query.setHost("ignored-while-running")
        #expect(query.host == "first-server")

        query.cancel(clearResults: clearResults)
        #expect(query.isRunning)
        #expect(!query.canRefresh)
        query.refresh(calendar: Self.calendar)
        #expect(await calls.values == ["remote"])
        await gate.release(summary)
        await query.waitUntilIdle()
        #expect(!query.isRunning)
        #expect(query.reports.count == (clearResults ? 0 : 1))
        #expect(query.message == (clearResults ? nil : "Cancelled"))
        query.setHost("next-server")
        #expect(query.canRefresh)
        #expect(query.reports.isEmpty)
    }

    @Test
    func `cancelling local history never starts SSH`() async throws {
        let summary = try Self.summary()
        let calls = Calls()
        let gate = Gate()
        let query = CodexSSHCostQuery(
            local: { _ in await gate.load() },
            remote: { _, _ in await calls.record("remote"); return summary })
        query.setHost("test-server")
        query.refresh(calendar: Self.calendar)
        await gate.waitUntilStarted()
        query.cancel(clearResults: true)
        await gate.release(summary)
        await query.waitUntilIdle()
        #expect(query.reports.isEmpty)
        #expect(await calls.values.isEmpty)
    }

    @Test
    func `presentation distinguishes missing zero small positive and partial costs`() throws {
        #expect(CodexSSHCostView.amountText(nil) == "Unknown")
        #expect(CodexSSHCostView.amountText(0) == "$0.00")
        #expect(CodexSSHCostView.amountText(0.00075) == "<$0.01")
        #expect(CodexSSHCostView.amountText(1.25) == "$1.25")
        let summary = try Self.summary(cost: nil, complete: false, unpriced: 2, incomplete: 3)
        let history = try CodexSSHCostReport.History(dailySummary: summary)
        let hints = CodexSSHCostView.coverageHints(history)
        #expect(hints.contains("Partial history; scan is incomplete."))
        #expect(hints.contains("Some usage has no known price."))
        #expect(hints.contains("Today: 3 incomplete requests excluded."))
        #expect(hints.contains("Last 30 days: 3 incomplete requests excluded."))
        #expect(CodexSSHCostView.hostTitle("private-user@private-host", hidden: true) == "SSH host")
        #expect(CodexSSHCostView.hostTitle("research-server", hidden: false) == "research-server")
    }

    private enum FixtureError: Error {
        case privatePath
    }

    @Test
    func `thirty daily points reach both chart metrics without model or session detail`() throws {
        let rows = (1...30).map { day in
            CostUsageDailyReport.Entry(
                date: String(format: "2026-04-%02d", day),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: day * 100,
                costUSD: Double(day) / 100,
                modelsUsed: ["fixture-model"],
                modelBreakdowns: [.init(modelName: "fixture-model", costUSD: Double(day) / 100)])
        }
        let source = try CostUsageTokenSnapshot(
            sessionTokens: 3000,
            sessionCostUSD: 0.3,
            last30DaysTokens: 46500,
            last30DaysCostUSD: 4.65,
            costProvenance: .listPriceEstimate,
            daily: rows,
            updatedAt: #require(ISO8601DateFormatter().date(from: "2026-04-30T12:00:00Z")))
        let history = try CodexSSHCostReport.History(
            dailySummary: CodexCostDailySummary(snapshot: source, calendar: Self.calendar))
        #expect(history.snapshot.daily.count == 30)
        #expect(history.snapshot.daily.allSatisfy { $0.modelsUsed == nil && $0.modelBreakdowns == nil })
        #expect(history.summary.history.totalTokens == 46500)
        #expect(CostHistoryChartMenuView._availableMetricsForTesting(
            provider: .codex, daily: history.snapshot.daily) == [.tokens, .cost])
        #expect(CostHistoryChartMenuView._chartValuesForTesting(
            provider: .codex, daily: history.snapshot.daily, metric: .tokens)
            == stride(from: 100.0, through: 3000, by: 100).map(\.self))
        let costs = CostHistoryChartMenuView._chartValuesForTesting(
            provider: .codex, daily: history.snapshot.daily, metric: .cost)
        #expect(costs.count == 30)
        #expect(costs.first == 0.01)
        #expect(costs.last == 0.3)
    }

    @Test
    func `unknown daily prices stay absent while real zero remains selectable`() throws {
        let unknown = try CodexSSHCostReport.History(dailySummary: Self.summary(cost: nil, unpriced: 1))
        let zero = try CodexSSHCostReport.History(dailySummary: Self.summary(cost: 0))
        #expect(unknown.summary.history.costUSD == nil)
        #expect(CostHistoryChartMenuView._chartValuesForTesting(
            provider: .codex, daily: unknown.snapshot.daily, metric: .cost).isEmpty)
        #expect(CostHistoryChartMenuView._chartValuesForTesting(
            provider: .codex, daily: zero.snapshot.daily, metric: .cost) == [0])
    }

    @Test
    func `daily reports use the requested Gregorian timezone and retain source timestamp and values`() async throws {
        let calls = Calls()
        let daily = try Self.summary(cost: 0.00075, timeZone: "Pacific/Kiritimati", incomplete: 2)
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let query = CodexSSHCostQuery(
            local: { calendar in
                await calls.record("\(calendar.identifier):\(calendar.timeZone.identifier)")
                return daily
            },
            remote: { host, calendar in
                await calls.record("\(host):\(calendar.identifier):\(calendar.timeZone.identifier)")
                return daily
            })
        query.setHost("fixture-server")
        query.refresh(calendar: calendar)
        await query.waitUntilIdle()

        #expect(await calls.values == ["gregorian:Pacific/Kiritimati", "fixture-server:gregorian:Pacific/Kiritimati"])
        let history = try #require(query.reports.last?.history)
        #expect(history.snapshot.updatedAt == ISO8601DateFormatter().date(from: "2026-05-01T07:00:00Z"))
        #expect(history.snapshot.daily.map(\.date) == ["2026-05-01"])
        #expect(history.snapshot.daily.first?.costUSD == 0.00075)
        #expect(history.snapshot.daily.first?.incompleteRequestCount == 2)
        #expect(history.snapshot.daily.first?.modelBreakdowns == nil)
        #expect(history.snapshot.daily.first?.modelsUsed == nil)
        #expect(history.snapshot.projects.isEmpty)
        #expect(history.snapshot.sessions.isEmpty)
        #expect(history.summary.today.totalTokens == 1000)
        #expect(history.summary.history.incompleteRequestCount == 2)
        #expect(history.calendar.timeZone.identifier == "Pacific/Kiritimati")
        #expect(history.dateRange.lowerBound == ISO8601DateFormatter().date(from: "2026-04-01T10:00:00Z"))
        #expect(history.dateRange.upperBound == ISO8601DateFormatter().date(from: "2026-05-01T10:00:00Z"))
    }

    @Test
    func `finished partial history still warns even after coverage was established`() async throws {
        let daily = try Self.summary(complete: true, partial: true)
        let query = CodexSSHCostQuery(local: { _ in daily }, remote: { _, _ in daily })
        query.setHost("fixture-server")
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()
        let history = try #require(query.reports.first?.history)
        #expect(!query.isRunning)
        #expect(history.snapshot.historyScanIsPartial)
        #expect(CodexSSHCostView.coverageHints(history).contains("Partial history; scan is incomplete."))
    }

    @Test
    func `mismatched remote timezone fails independently with daily CLI guidance`() async throws {
        let local = try Self.summary()
        let wrongZone = try Self.summary(timeZone: "Asia/Shanghai")
        let query = CodexSSHCostQuery(local: { _ in local }, remote: { _, _ in wrongZone })
        query.setHost("fixture-server")
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()
        #expect(query.reports.first?.history?.dailySummary == local)
        #expect(query.reports.last?.history == nil)
        #expect(query.reports.last?.error?.contains("--daily-summary") == true)
    }

    @Test
    func `closing the window clears completed reports without starting another query`() async throws {
        let daily = try Self.summary()
        let query = CodexSSHCostQuery(local: { _ in daily }, remote: { _, _ in daily })
        let controller = CodexSSHCostWindowController(query: query, content: EmptyView())
        query.setHost("fixture-server")
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()
        #expect(query.reports.count == 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(query.reports.isEmpty)
        #expect(!query.isRunning)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func summary(
        cost: Double? = 1.25,
        updatedAt: String = "2026-05-01T07:00:00Z",
        timeZone: String = "GMT",
        complete: Bool = true,
        partial: Bool = false,
        unpriced: Int = 0,
        incomplete: Int = 0) throws -> CodexCostDailySummary
    {
        let window: [String: Any] = [
            "date": "2026-05-01",
            "totalTokens": 1000,
            "costUSD": cost.map { $0 as Any } ?? NSNull(),
            "incompleteRequestCount": incomplete,
            "coverage": ["priced": 1, "unpriced": unpriced, "unmetered": 0, "estimated": 0],
        ]
        let object: [String: Any] = [
            "schemaVersion": 1, "kind": "daily", "provider": "codex", "updatedAt": updatedAt,
            "bucketTimeZone": timeZone, "currencyCode": "USD", "historyDays": 30,
            "historyCoverageIsEstablished": complete, "historyScanIsPartial": partial,
            "costProvenance": "listPriceEstimate", "daily": [window],
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexCostDailySummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private actor Calls {
        var values: [String] = []

        func record(_ value: String) {
            self.values.append(value)
        }
    }

    private actor Gate {
        private var result: CheckedContinuation<CodexCostDailySummary, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func load() async -> CodexCostDailySummary {
            await withCheckedContinuation { continuation in
                self.result = continuation
                self.started?.resume()
                self.started = nil
            }
        }

        func waitUntilStarted() async {
            guard self.result == nil else { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func release(_ summary: CodexCostDailySummary) {
            self.result?.resume(returning: summary)
            self.result = nil
        }
    }
}

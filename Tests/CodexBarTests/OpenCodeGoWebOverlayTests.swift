import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeGoWebOverlayTests {
    private static let updatedAt = Date(timeIntervalSince1970: 1_784_836_525)
    private static let renewsAt = Date(timeIntervalSince1970: 1_786_550_400)

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []

        func append(_ value: Value) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage.append(value)
        }

        var values: [Value] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private static func dailyEntry() -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: "2026-07-20",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            requestCount: 748,
            costUSD: 11.52,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    /// Mirrors the mis-anchored local estimate: earliest local row far before the real billing
    /// cycle, so the monthly window sums more than the $60 plan limit and clamps to 100%.
    private static func localEstimate(zenBalanceUSD: Double? = nil) -> OpenCodeGoUsageSnapshot {
        OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 49.4,
            monthlyUsagePercent: 100,
            rollingResetInSec: 18000,
            weeklyResetInSec: 266_400,
            monthlyResetInSec: 266_400,
            zenBalanceUSD: zenBalanceUSD,
            daily: [self.dailyEntry()],
            updatedAt: self.updatedAt)
    }

    private static func webUsage(zenBalanceUSD: Double? = nil) -> OpenCodeGoUsageSnapshot {
        OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 52,
            monthlyUsagePercent: 64,
            rollingResetInSec: 18000,
            weeklyResetInSec: 266_400,
            monthlyResetInSec: 1_539_000,
            zenBalanceUSD: zenBalanceUSD,
            renewsAt: self.renewsAt,
            updatedAt: self.updatedAt.addingTimeInterval(2))
    }

    private func makeContext(
        includeOptionalUsage: Bool = true,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private func makeManualCookieSettings() -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .manual,
            manualCookieHeader: "auth=test",
            workspaceID: nil))
    }

    @Test
    func `overlay replaces estimated windows with server values and keeps local daily`() {
        let merged = Self.localEstimate().applyingWebUsage(Self.webUsage(zenBalanceUSD: 42.5))

        #expect(merged.rollingUsagePercent == 0)
        #expect(merged.weeklyUsagePercent == 52)
        #expect(merged.monthlyUsagePercent == 64)
        #expect(merged.monthlyResetInSec == 1_539_000)
        #expect(merged.hasWeeklyUsage)
        #expect(merged.hasMonthlyUsage)
        #expect(merged.zenBalanceUSD == 42.5)
        #expect(merged.renewsAt == Self.renewsAt)
        #expect(merged.daily.count == 1)
        #expect(merged.daily.first?.costUSD == 11.52)
        #expect(merged.updatedAt == Self.updatedAt)
        #expect(!merged.isBalanceOnly)
    }

    @Test
    func `overlay keeps local zen balance when web usage has none`() {
        let merged = Self.localEstimate(zenBalanceUSD: 7.25).applyingWebUsage(Self.webUsage())

        #expect(merged.zenBalanceUSD == 7.25)
        #expect(merged.monthlyUsagePercent == 64)
    }

    @Test
    func `overlay keeps local renewal date when web usage has none`() {
        let local = Self.localEstimate()
        let merged = local.applyingWebUsage(Self.webUsage())

        #expect(merged.renewsAt == Self.renewsAt)
        let webWithoutRenewal = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 1,
            weeklyUsagePercent: 2,
            monthlyUsagePercent: 3,
            rollingResetInSec: 1,
            weeklyResetInSec: 2,
            monthlyResetInSec: 3,
            renewsAt: nil,
            updatedAt: Self.updatedAt)
        #expect(local.applyingWebUsage(webWithoutRenewal).renewsAt == nil)
    }

    @Test
    func `balance only web response keeps local windows and adopts balance`() {
        let web = OpenCodeGoUsageSnapshot.zenBalanceOnly(balanceUSD: 42.5, updatedAt: Self.updatedAt)
        let merged = Self.localEstimate().applyingWebUsage(web)

        #expect(merged.monthlyUsagePercent == 100)
        #expect(merged.monthlyResetInSec == 266_400)
        #expect(merged.zenBalanceUSD == 42.5)
        #expect(merged.daily.count == 1)
        #expect(!merged.isBalanceOnly)
    }

    @Test
    func `overlaid snapshot projects server monthly window into usage snapshot`() {
        let merged = Self.localEstimate().applyingWebUsage(Self.webUsage())
        let usage = merged.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.secondary?.usedPercent == 52)
        #expect(usage.tertiary?.usedPercent == 64)
        #expect(usage.tertiary?.resetsAt == Self.updatedAt.addingTimeInterval(1_539_000))
        #expect(usage.opencodegoUsage?.daily.count == 1)
        #expect(usage.extraRateWindows?.contains { $0.id == "renewal" } == true)
    }

    @Test
    func `local strategy overlays authoritative web usage when a cookie is configured`() async throws {
        let observedCookies = Recorder<String>()
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, cookieHeader in
                observedCookies.append(cookieHeader)
                return Self.webUsage(zenBalanceUSD: 42.5)
            })

        let result = try await strategy.fetch(self.makeContext(settings: self.makeManualCookieSettings()))

        #expect(result.sourceLabel == "local+web")
        #expect(observedCookies.values == ["auth=test"])
        #expect(result.usage.tertiary?.usedPercent == 64)
        #expect(result.usage.secondary?.usedPercent == 52)
        #expect(result.usage.opencodegoUsage?.daily.count == 1)
        #expect(result.usage.providerCost?.used == 42.5)
    }

    @Test
    func `local strategy keeps local estimate when web overlay is unavailable`() async throws {
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, _ in nil })

        let result = try await strategy.fetch(self.makeContext(
            includeOptionalUsage: false,
            settings: self.makeManualCookieSettings()))

        #expect(result.sourceLabel == "local")
        #expect(result.usage.tertiary?.usedPercent == 100)
    }

    @Test
    func `local strategy does not consult web usage when cookies are disabled`() async throws {
        let webCalls = Recorder<String>()
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, cookieHeader in
                webCalls.append(cookieHeader)
                return Self.webUsage()
            })
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .off,
            manualCookieHeader: nil,
            workspaceID: nil))

        let result = try await strategy.fetch(self.makeContext(settings: settings))

        #expect(webCalls.values.isEmpty)
        #expect(result.sourceLabel == "local")
        #expect(result.usage.tertiary?.usedPercent == 100)
    }

    @Test
    func `local strategy propagates cancellation from the web overlay`() async {
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, _ in throw CancellationError() })

        await #expect(throws: CancellationError.self) {
            try await strategy.fetch(self.makeContext(settings: self.makeManualCookieSettings()))
        }
    }

    @Test
    func `local strategy propagates url session cancellation from the web overlay`() async {
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, _ in throw URLError(.cancelled) })

        await #expect(throws: CancellationError.self) {
            try await strategy.fetch(self.makeContext(settings: self.makeManualCookieSettings()))
        }
    }
}

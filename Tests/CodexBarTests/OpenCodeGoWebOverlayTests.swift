import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
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
        settings: ProviderSettingsSnapshot? = nil,
        env: [String: String] = [:],
        selectedTokenAccountID: UUID? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selectedTokenAccountID)
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
        #expect(result.usage.dataConfidence != .estimated)
    }

    @Test
    func `selected token account credential reaches the authoritative overlay`() async throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Selected",
            token: "auth=selected",
            addedAt: 0,
            lastUsed: nil)
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let contribution = try #require(descriptor.settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(config: nil, account: account)))
        let settings = ProviderSettingsSnapshot(contributions: [contribution])
        let observedCookies = Recorder<String>()
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, cookieHeader in
                observedCookies.append(cookieHeader)
                return Self.webUsage()
            })

        let result = try await strategy.fetch(self.makeContext(
            settings: settings,
            selectedTokenAccountID: account.id))

        #expect(settings.opencodego?.cookieSource == .manual)
        #expect(observedCookies.values == ["auth=selected"])
        #expect(result.sourceLabel == "local+web")
        #expect(result.usage.tertiary?.usedPercent == 64)
        #expect(result.usage.dataConfidence != .estimated)
    }

    @Test
    func `manual token authentication failure is surfaced instead of returning local estimate`() async {
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, _ in throw OpenCodeGoUsageError.invalidCredentials })

        do {
            _ = try await strategy.fetch(self.makeContext(settings: self.makeManualCookieSettings()))
            Issue.record("Expected the invalid manual session to fail")
        } catch OpenCodeGoUsageError.invalidCredentials {
            // Expected: an explicit account credential must not degrade to account-agnostic local usage.
        } catch {
            Issue.record("Expected invalidCredentials, got \(error)")
        }
    }

    @Test
    func `local strategy prefers API windows while preserving local history and web balance`() async throws {
        let observedKeys = Recorder<String>()
        let webCalls = Recorder<String>()
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, cookieHeader in
                webCalls.append(cookieHeader)
                return Self.webUsage(zenBalanceUSD: 42.5)
            },
            apiUsageOverlayFetcher: { _, apiKey in
                observedKeys.append(apiKey)
                return OpenCodeGoUsageSnapshot(
                    hasMonthlyUsage: true,
                    rollingUsagePercent: 11,
                    weeklyUsagePercent: 22,
                    monthlyUsagePercent: 33,
                    rollingResetInSec: 18100,
                    weeklyResetInSec: 266_500,
                    monthlyResetInSec: 1_539_100,
                    updatedAt: Self.updatedAt.addingTimeInterval(3))
            })

        let result = try await strategy.fetch(self.makeContext(
            settings: self.makeManualCookieSettings(),
            env: [OpenCodeGoSettingsReader.apiKeyEnvironmentKey: "go_test"]))

        #expect(result.sourceLabel == "local+api")
        #expect(observedKeys.values == ["go_test"])
        #expect(webCalls.values == ["auth=test"])
        #expect(result.usage.primary?.usedPercent == 11)
        #expect(result.usage.secondary?.usedPercent == 22)
        #expect(result.usage.tertiary?.usedPercent == 33)
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
        #expect(result.usage.dataConfidence == .estimated)
    }

    @Test
    func `balance only web response keeps local quota marked estimated`() async throws {
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in Self.localEstimate() },
            webUsageOverlayFetcher: { _, _ in
                OpenCodeGoUsageSnapshot.zenBalanceOnly(balanceUSD: 42.5, updatedAt: Self.updatedAt)
            })

        let result = try await strategy.fetch(self.makeContext(settings: self.makeManualCookieSettings()))

        #expect(result.sourceLabel == "local+web")
        #expect(result.usage.tertiary?.usedPercent == 100)
        #expect(result.usage.providerCost?.used == 42.5)
        #expect(result.usage.dataConfidence == .estimated)
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
        #expect(result.usage.dataConfidence == .estimated)
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

    #if os(macOS)
    @Test
    func `empty cookie cache marks local quota windows estimated`() async throws {
        try await self.withEmptyCookieCache {
            let webCalls = Recorder<String>()
            let strategy = OpenCodeGoLocalUsageFetchStrategy(
                localSnapshotLoader: { _ in Self.localEstimate() },
                webUsageOverlayFetcher: { _, cookieHeader in
                    webCalls.append(cookieHeader)
                    return Self.webUsage()
                })

            let result = try await strategy.fetch(self.makeContext(includeOptionalUsage: false))

            #expect(webCalls.values.isEmpty)
            #expect(result.sourceLabel == "local")
            #expect(result.usage.secondary?.usedPercent == 49.4)
            #expect(result.usage.tertiary?.usedPercent == 100)
            #expect(result.usage.dataConfidence == .estimated)
        }
    }

    @Test
    func `local strategy evicts cached cookie after authentication failure`() async throws {
        try await self.withCachedCookie {
            let strategy = OpenCodeGoLocalUsageFetchStrategy(
                localSnapshotLoader: { _ in Self.localEstimate() },
                webUsageOverlayFetcher: { _, _ in throw OpenCodeGoUsageError.invalidCredentials })

            let result = try await strategy.fetch(self.makeContext(includeOptionalUsage: false))

            #expect(result.sourceLabel == "local")
            #expect(result.usage.tertiary?.usedPercent == 100)
            #expect(CookieHeaderCache.load(provider: .opencodego) == nil)
        }
    }

    @Test
    func `local strategy retains cached cookie after transport failure`() async throws {
        try await self.withCachedCookie {
            let strategy = OpenCodeGoLocalUsageFetchStrategy(
                localSnapshotLoader: { _ in Self.localEstimate() },
                webUsageOverlayFetcher: { _, _ in throw URLError(.timedOut) })

            let result = try await strategy.fetch(self.makeContext(includeOptionalUsage: false))

            #expect(result.sourceLabel == "local")
            #expect(result.usage.tertiary?.usedPercent == 100)
            #expect(CookieHeaderCache.load(provider: .opencodego)?.cookieHeader == "auth=cached-session")
        }
    }

    @Test
    func `local strategy reuses valid cached cookie`() async throws {
        try await self.withCachedCookie {
            let observedCookies = Recorder<String>()
            let strategy = OpenCodeGoLocalUsageFetchStrategy(
                localSnapshotLoader: { _ in Self.localEstimate() },
                webUsageOverlayFetcher: { _, cookieHeader in
                    observedCookies.append(cookieHeader)
                    return Self.webUsage()
                })

            let result = try await strategy.fetch(self.makeContext(includeOptionalUsage: false))

            #expect(result.sourceLabel == "local+web")
            #expect(result.usage.tertiary?.usedPercent == 64)
            #expect(result.usage.dataConfidence != .estimated)
            #expect(observedCookies.values == ["auth=cached-session"])
            #expect(CookieHeaderCache.load(provider: .opencodego)?.cookieHeader == "auth=cached-session")
        }
    }

    private func withEmptyCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        let service = "com.steipete.codexbar.tests.opencodego-overlay-empty.\(UUID().uuidString)"
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.resetDisplayCacheForTesting()
                defer { CookieHeaderCache.resetDisplayCacheForTesting() }
                return try await operation()
            }
        }
    }

    private func withCachedCookie<T>(_ operation: () async throws -> T) async rethrows -> T {
        let service = "com.steipete.codexbar.tests.opencodego-overlay.\(UUID().uuidString)"
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.resetDisplayCacheForTesting()
                defer { CookieHeaderCache.resetDisplayCacheForTesting() }
                CookieHeaderCache.store(
                    provider: .opencodego,
                    cookieHeader: "auth=cached-session",
                    sourceLabel: "Chrome")
                return try await operation()
            }
        }
    }
    #endif
}

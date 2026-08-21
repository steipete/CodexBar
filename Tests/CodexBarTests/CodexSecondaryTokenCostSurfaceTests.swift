import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexSecondaryTokenCostSurfaceTests {
    @Test
    func `profile scoped menu bar editor and overview hide incompatible raw cost until current publication`() throws {
        let (settings, store) = Self.makeFixture(ambient: false)
        let profileA = "/tmp/secondary-surface-profile-a"
        let profileB = "/tmp/secondary-surface-profile-b"
        Self.configureProfiles(settings: settings, profileA: profileA, profileB: profileB)
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let usage = Self.usageSnapshot(now: now)
        store._setSnapshotForTesting(usage, provider: .codex)
        let profileASnapshot = Self.tokenSnapshot(cost: 1, now: now)
        store._setTokenSnapshotForTesting(profileASnapshot, provider: .codex)
        let controller = Self.controller(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        try Self.expectSecondaryCosts(
            expected: 1,
            settings: settings,
            store: store,
            controller: controller,
            usage: usage)

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshot(for: .codex) == profileASnapshot)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
        Self.expectSecondaryCostsHidden(
            settings: settings,
            store: store,
            controller: controller,
            usage: usage)

        store._setTokenSnapshotForTesting(Self.tokenSnapshot(cost: 2, now: now), provider: .codex)

        try Self.expectSecondaryCosts(
            expected: 2,
            settings: settings,
            store: store,
            controller: controller,
            usage: usage)
    }

    @Test
    func `ambient menu bar editor and overview cost remains visible across profile selection`() throws {
        let (settings, store) = Self.makeFixture(ambient: true)
        let profileA = "/tmp/secondary-surface-ambient-a"
        let profileB = "/tmp/secondary-surface-ambient-b"
        Self.configureProfiles(settings: settings, profileA: profileA, profileB: profileB)
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let usage = Self.usageSnapshot(now: now)
        store._setSnapshotForTesting(usage, provider: .codex)
        let snapshot = Self.tokenSnapshot(cost: 3, now: now)
        store._setTokenSnapshotForTesting(snapshot, provider: .codex)
        let controller = Self.controller(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == snapshot)
        try Self.expectSecondaryCosts(
            expected: 3,
            settings: settings,
            store: store,
            controller: controller,
            usage: usage)
    }

    @Test
    func `Spend Dashboard keeps profile inputs scoped and ambient publication shared`() async throws {
        let profileAURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-secondary-dashboard-a-\(UUID().uuidString)", isDirectory: true)
        let profileBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-secondary-dashboard-b-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: profileAURL, email: "profile-a@example.com")
        try Self.writeCodexAuthFile(homeURL: profileBURL, email: "profile-b@example.com")
        defer {
            try? FileManager.default.removeItem(at: profileAURL)
            try? FileManager.default.removeItem(at: profileBURL)
        }

        let (settings, store) = Self.makeFixture(ambient: false)
        let missingLiveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-secondary-dashboard-missing-\(UUID().uuidString)", isDirectory: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        defer { settings._test_codexReconciliationEnvironment = nil }
        Self.configureProfiles(
            settings: settings,
            profileA: profileAURL.path,
            profileB: profileBURL.path)
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let rawProfileA = Self.tokenSnapshot(cost: 1, now: now)
        store._setTokenSnapshotForTesting(rawProfileA, provider: .codex)

        settings.codexActiveSource = .profileHome(path: profileBURL.path)
        let profileRequest = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly,
            now: now)

        #expect(store.tokenSnapshot(for: .codex) == rawProfileA)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
        #expect(profileRequest.capturedInputs.allSatisfy { $0.provider != .codex })
        #expect(Set(profileRequest.codexRequests.map(\.homePath)) == [profileAURL.path, profileBURL.path])
        let profileResult = await Self.loadSpendDashboard(
            request: profileRequest,
            snapshotsByHome: [
                profileAURL.path: Self.tokenSnapshot(cost: 1, now: now),
                profileBURL.path: Self.tokenSnapshot(cost: 2, now: now),
            ])
        try Self.expectSpendDashboardAttribution(
            request: profileRequest,
            result: profileResult,
            costsByHome: [profileAURL.path: 1, profileBURL.path: 2])

        settings.codexLocalSessionCostLedgerEnabled = true
        settings.codexActiveSource = .profileHome(path: profileAURL.path)
        let ambientSnapshot = Self.tokenSnapshot(cost: 4, now: now)
        store._setTokenSnapshotForTesting(ambientSnapshot, provider: .codex)
        settings.codexActiveSource = .profileHome(path: profileBURL.path)
        let ambientRequest = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly,
            now: now)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == ambientSnapshot)
        #expect(ambientRequest.capturedInputs.allSatisfy { $0.provider != .codex })
        #expect(Set(ambientRequest.codexRequests.map(\.homePath)) == [profileAURL.path, profileBURL.path])
        let ambientResult = await Self.loadSpendDashboard(
            request: ambientRequest,
            snapshotsByHome: [
                profileAURL.path: Self.tokenSnapshot(cost: 5, now: now),
                profileBURL.path: Self.tokenSnapshot(cost: 6, now: now),
            ])
        try Self.expectSpendDashboardAttribution(
            request: ambientRequest,
            result: ambientResult,
            costsByHome: [profileAURL.path: 5, profileBURL.path: 6])
    }

    private static func loadSpendDashboard(
        request: SpendDashboardLoadRequest,
        snapshotsByHome: [String: CostUsageTokenSnapshot]) async -> SpendDashboardLoadResult
    {
        await SpendDashboardSource.load(request, codexSnapshotLoader: { context in
            guard let snapshot = snapshotsByHome[context.account.homePath] else {
                throw UnexpectedCodexHomeError(homePath: context.account.homePath)
            }
            return snapshot
        })
    }

    private static func expectSpendDashboardAttribution(
        request: SpendDashboardLoadRequest,
        result: SpendDashboardLoadResult,
        costsByHome: [String: Double]) throws
    {
        #expect(result.failedSourceIDs.isEmpty)
        #expect(result.invalidatedSourceIDs.isEmpty)
        #expect(result.inputs.count == costsByHome.count)

        let model = SpendDashboardModel.build(
            inputs: result.inputs,
            requestedDays: 30,
            now: request.now,
            calendar: request.configuration.bucketCalendar)
        let group = try #require(model.groups.first)
        #expect(group.providers.count == costsByHome.count)
        #expect(model.availableSources.count == costsByHome.count)

        for (homePath, expectedCost) in costsByHome {
            let account = try #require(request.codexRequests.first { $0.homePath == homePath })
            let sourceID = "codex:\(account.id)"
            let input = try #require(result.inputs.first { $0.id == sourceID })
            #expect(input.displayName == account.displayName)
            #expect(input.snapshot.last30DaysCostUSD == expectedCost)

            let source = try #require(model.availableSources.first { $0.id == sourceID })
            #expect(source.displayName == account.displayName)
            let provider = try #require(group.providers.first { $0.id == sourceID })
            #expect(provider.displayName == account.displayName)
            #expect(provider.totalCost == expectedCost)
        }
    }

    private struct UnexpectedCodexHomeError: Error {
        let homePath: String
    }

    private static func expectSecondaryCosts(
        expected: Double,
        settings: SettingsStore,
        store: UsageStore,
        controller: StatusItemController,
        usage: UsageSnapshot) throws
    {
        let now = usage.updatedAt
        let formatted = UsageFormatter.currencyString(expected, currencyCode: "USD")
        #expect(controller.menuBarLayoutCosts(provider: .codex, now: now).last30Days == formatted)
        let preview = MenuBarLayoutPreview(
            layout: MenuBarLayout(lines: [[.cost30d]]),
            provider: .codex,
            settings: settings,
            store: store)
            .liveData(provider: .codex, snapshot: usage)
        #expect(preview.cost30d == formatted)
        let overview = controller.overviewSpendDashboardModel(providers: [.codex], now: now)
        #expect(try #require(overview.groups.first).totalCost == expected)
    }

    private static func expectSecondaryCostsHidden(
        settings: SettingsStore,
        store: UsageStore,
        controller: StatusItemController,
        usage: UsageSnapshot)
    {
        let now = usage.updatedAt
        #expect(controller.menuBarLayoutCosts(provider: .codex, now: now).last30Days == nil)
        let preview = MenuBarLayoutPreview(
            layout: MenuBarLayout(lines: [[.cost30d]]),
            provider: .codex,
            settings: settings,
            store: store)
            .liveData(provider: .codex, snapshot: usage)
        #expect(preview.cost30d == nil)
        #expect(controller.overviewSpendDashboardModel(providers: [.codex], now: now).groups.isEmpty)
    }

    private static func makeFixture(ambient: Bool) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "CodexSecondaryTokenCostSurfaceTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = ambient
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }

    private static func configureProfiles(
        settings: SettingsStore,
        profileA: String,
        profileB: String)
    {
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": "pro",
        ])
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let token = "\(base64URL(header)).\(base64URL(payload))."
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": token,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func controller(settings: SettingsStore, store: UsageStore) -> StatusItemController {
        StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private static func usageSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
    }

    private static func tokenSnapshot(cost: Double, now: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 20,
            last30DaysCostUSD: cost,
            currencyCode: "USD",
            daily: [CostUsageDailyReport.Entry(
                date: "2026-08-22",
                inputTokens: 4,
                outputTokens: 6,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: nil)],
            updatedAt: now)
    }
}

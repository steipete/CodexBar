import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeSwapLocalCostTests {
    @Test
    func `legacy adapter config loads without a profile mapping`() throws {
        let json = """
        {
          "id": "claude",
          "enabled": true,
          "source": "cli",
          "cookieSource": "off",
          "claudeSwapEnabled": true,
          "claudeSwapExecutablePath": "/fixture/legacy-adapter",
          "claudeSwapShowSingleAccount": true
        }
        """
        let legacy = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        let roundTrip = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(legacy))
        #expect(roundTrip.claudeSwapCostProfiles == nil)
        #expect(roundTrip.enabled == true)
        #expect(roundTrip.source == .cli)
        #expect(roundTrip.cookieSource == .off)
        #expect(roundTrip.claudeSwapEnabled == true)
        #expect(roundTrip.claudeSwapExecutablePath == "/fixture/legacy-adapter")
        #expect(roundTrip.claudeSwapShowSingleAccount == true)
    }

    @Test
    func `profile costs follow the account identity across switches and slot reuse`() async throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let (store, settings, now, personal) = (fixture.store, fixture.settings, fixture.now, fixture.personal)
        let organization = Fixture.organization

        fixture.publish(
            [fixture.account(1, active: true), fixture.account(2, organizationUuid: organization)],
            active: 1)
        store.scheduleClaudeSwapLocalCostRefresh(now: now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [110, 210])
        for (account, tokens) in zip(store.claudeSwapAccountSnapshots, [110, 210]) {
            let context = ClaudeSwapAccountMenuDisplay.cardContext(
                for: account,
                planLabel: nil,
                adapterError: nil,
                switchError: nil,
                localTokenCost: store.claudeSwapLocalTokenCost(for: account))
            let estimate = store.menuCardInput(for: .claude, context: context).tokenSnapshot
            #expect(estimate?.last30DaysTokens == tokens)
            #expect(estimate?.last30DaysCostUSD != nil)
        }

        fixture.publish(
            [fixture.account(2), fixture.account(1, organizationUuid: organization, active: true)],
            active: 1)
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [210, 110])

        fixture.publish(
            [fixture.account(2), fixture.account(1, active: true, email: "replacement@example.com")],
            active: 1)
        store.scheduleClaudeSwapLocalCostRefresh(now: now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [nil, 110])

        let mappedAccount = store.claudeSwapAccountSnapshots[1]
        for (period, label) in [(CostReportingPeriod.monthToDate, "Month to date"), (.allTime, "All")] {
            settings.costReportingPeriod = period
            #expect(store.claudeSwapLocalTokenCost(for: mappedAccount) == nil)
            store.scheduleClaudeSwapLocalCostRefresh(now: now)
            await store.claudeSwapLocalCostState.task?.value
            let estimate = try #require(store.claudeSwapLocalTokenCost(for: mappedAccount))
            #expect(estimate.last30DaysTokens == 110)
            #expect(estimate.reportingPeriod == period)
            #expect(estimate.historyLabel == label)
        }

        try FileManager.default.removeItem(at: personal)
        store.scheduleClaudeSwapLocalCostRefresh(force: true, now: now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.allSatisfy { store.claudeSwapLocalTokenCost(for: $0) == nil })
    }

    @Test
    func `each mapped profile keeps its own transcript cache`() async throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let store = fixture.store
        fixture.publish(
            [fixture.account(1, active: true), fixture.account(2, organizationUuid: Fixture.organization)],
            active: 1)

        func cacheFile(for directory: URL?) -> URL {
            CostUsageClaudeCacheIO.cacheFileURL(
                provider: .claude,
                cacheRoot: directory.map {
                    CostUsageFetcher.claudeDirectoryCacheRoot(
                        cacheRoot: fixture.environment.cacheRoot, configDirectory: $0.path)
                } ?? fixture.environment.cacheRoot)
        }

        store.scheduleClaudeSwapLocalCostRefresh(now: fixture.now)
        await store.claudeSwapLocalCostState.task?.value
        let personalCache = cacheFile(for: fixture.personal)
        let workCache = cacheFile(for: fixture.work)
        #expect(personalCache != workCache)
        let personalBytes = try Data(contentsOf: personalCache)
        let workBytes = try Data(contentsOf: workCache)
        #expect(!FileManager.default.fileExists(atPath: cacheFile(for: nil).path))

        // The ambient scan keeps the shared artifact, and a later profile refresh finds its own rows untouched.
        let ambient = try await store.loadTokenUsageSnapshot(
            provider: .claude, force: false, now: fixture.now, codexHomePath: nil, historyDays: 30)
        #expect(ambient.snapshot.last30DaysTokens == 310)
        #expect(FileManager.default.fileExists(atPath: cacheFile(for: nil).path))
        store.claudeSwapLocalCostState.attemptedAt = nil
        store.scheduleClaudeSwapLocalCostRefresh(now: fixture.now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(try Data(contentsOf: personalCache) == personalBytes)
        #expect(try Data(contentsOf: workCache) == workBytes)
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [110, 210])
    }

    @Test
    func `clearing the cost cache clears profile estimates and permits a refresh`() async throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let store = fixture.store
        fixture.publish(
            [fixture.account(1, active: true), fixture.account(2, organizationUuid: Fixture.organization)],
            active: 1)
        store.scheduleClaudeSwapLocalCostRefresh(now: fixture.now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.allSatisfy { store.claudeSwapLocalTokenCost(for: $0) != nil })
        let revision = store.claudeSwapRevision

        let caches = fixture.environment.root.appendingPathComponent("caches")
        let error = await store.clearCostUsageCache(fileManagerFactory: { CacheFileManager(root: caches) })
        #expect(error == nil)
        #expect(store.claudeSwapAccountSnapshots.allSatisfy { store.claudeSwapLocalTokenCost(for: $0) == nil })
        #expect(store.claudeSwapLocalCostState.attemptedAt == nil)
        #expect(store.claudeSwapRevision != revision)

        store.scheduleClaudeSwapLocalCostRefresh(now: fixture.now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [110, 210])
    }
}

/// Personal and Work profile histories plus an ambient history, priced at a flat synthetic rate.
@MainActor
private struct Fixture {
    static let email = "account@example.com"
    static let organization = "00000000-0000-0000-0000-000000000001"

    let environment: CostUsageTestEnvironment
    let now: Date
    let personal: URL
    let work: URL
    let settings: SettingsStore
    let store: UsageStore

    init() throws {
        let environment = try CostUsageTestEnvironment()
        let now = Date()
        let personal = environment.root.appendingPathComponent("personal")
        let work = environment.root.appendingPathComponent("work")
        let ambient = environment.root.appendingPathComponent("ambient")
        for (index, root) in [personal, work, ambient].enumerated() {
            let project = root.appendingPathComponent("projects/sample")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let row: [String: Any] = [
                "type": "assistant", "timestamp": environment.isoString(for: now),
                "requestId": "request-\(index)",
                "message": [
                    "id": "message-\(index)",
                    "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": (index + 1) * 100, "output_tokens": 10],
                ],
            ]
            try environment.jsonl([row]).write(
                to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        }
        #expect(try ModelsDevCache.save(
            catalog: CostUsageClaudeResolverTests.simpleCatalog(["claude-sonnet-4-20250514": 3]),
            fetchedAt: now,
            cacheRoot: environment.cacheRoot))
        let settings = testSettingsStore(
            suiteName: "ClaudeSwapLocalCostTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        enableTestProviders([.claude], settings: settings)
        settings.costUsageEnabled = true
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = "/fixture/unused-adapter"
        settings.updateProviderConfig(provider: .claude) {
            $0.claudeSwapCostProfiles = [
                .init(email: Self.email.uppercased(), configDirectory: personal.path),
                .init(email: Self.email, organizationUuid: Self.organization, configDirectory: work.path),
            ]
        }
        self.environment = environment
        self.now = now
        self.personal = personal
        self.work = work
        self.settings = settings
        self.store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: .init(
                claudeProjectsRoots: [ambient.appendingPathComponent("projects")],
                cacheRoot: environment.cacheRoot)),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["HOME": environment.root.path],
            widgetSnapshotURL: environment.root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
    }

    func account(
        _ number: Int,
        organizationUuid: String = "",
        active: Bool = false,
        email: String? = nil) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email ?? Self.email,
            organizationUuid: organizationUuid,
            isActive: active,
            usageStatus: .ok,
            fiveHour: nil,
            sevenDay: nil)
    }

    func publish(_ rows: [ClaudeSwapAccountRow], active: Int) {
        self.store.claudeSwapAccountSnapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: active, accounts: rows))
    }
}

/// Points the cache-clear action at a fixture Caches directory instead of the user's.
private final class CacheFileManager: FileManager, @unchecked Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .cachesDirectory && domainMask == .userDomainMask ? [self.root] : []
    }
}

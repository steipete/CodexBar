import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardCachedPresentationTests {
    @Test
    func `empty dashboard distinguishes active refresh from converged empty history`() {
        #expect(SpendDashboardEmptyState.make(isRefreshing: true).title == L("Refreshing"))
        #expect(SpendDashboardEmptyState.make(isRefreshing: false).title == L("No local cost history yet"))
    }

    @Test
    func `production loader reads a validated scoped account report`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let historyDays = 30
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 15)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "dashboard-cached.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: day),
                    "payload": ["model": "gpt-5.2"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 42,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                            "model": "gpt-5.2",
                        ],
                    ],
                ],
            ]))
        _ = try await CostUsageFetcher(cacheRoot: env.cacheRoot).loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: historyDays,
            includePiSessions: false)
        let account = CodexSpendScanRequest(
            id: "profile",
            displayName: "Codex profile",
            source: .profileHome(path: env.codexHomeRoot.path),
            homePath: env.codexHomeRoot.path,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "profile-cache")
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: ["profile|profile-cache"]),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: day,
            force: false,
            historyDays: historyDays)
        let cacheRoot = env.cacheRoot

        let result = await SpendDashboardSource.loadCached(request, cacheRootResolver: { _ in cacheRoot })

        #expect(result.inputs.count == 1)
        #expect(result.inputs.first?.id == "codex:profile")
        #expect(result.inputs.first?.snapshot.sessionTokens == 42)
        #expect(result.inputs.first?.snapshot.projects.isEmpty == true)
        #expect(result.inputs.first?.snapshot.sessions.isEmpty == true)
    }

    @Test
    func `retained Codex totals render during refresh and clear only after convergence`() async {
        let gate = SpendDashboardCachedLoaderGate()
        let configuration = Self.configuration(account: "account|cache")
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                Self.request(configuration: configuration, force: mode.forcesLoader)
            },
            cachedLoader: { _ in
                SpendDashboardLoadResult(
                    inputs: [Self.input(id: "codex:account", cost: 3)],
                    failedSourceIDs: [])
            },
            loader: { request in await gate.load(request) })

        controller.update(configuration: configuration)
        await Self.waitForPendingCount(1, gate: gate)

        #expect(controller.isRefreshing)
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex:account"])

        await gate.resume(at: 0, result: .init(inputs: [], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.isEmpty)
    }

    @Test
    func `cached Codex totals stay bound to their account cache`() async {
        let first = Self.scanRequest(id: "first", cacheIdentity: "first-cache")
        let second = Self.scanRequest(id: "second", cacheIdentity: "second-cache")
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: ["first|first-cache", "second|second-cache"]),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [first, second],
            now: Self.fixtureNow,
            force: false,
            historyDays: 365)

        let result = await SpendDashboardSource.loadCached(request, cachedCodexSnapshotLoader: { context in
            switch context.account.id {
            case "first": Self.input(cost: 2, historyDays: context.historyDays).snapshot
            case "second": Self.input(cost: 5, historyDays: context.historyDays).snapshot
            default: nil
            }
        })

        #expect(Dictionary(uniqueKeysWithValues: result.inputs.map { ($0.id, $0.snapshot.last30DaysCostUSD) }) == [
            "codex:first": 2,
            "codex:second": 5,
        ])
        #expect(result.inputs.allSatisfy { $0.snapshot.historyDays == 365 })
        #expect(SpendDashboardSource.codexCacheRoot(for: first).lastPathComponent == "first-cache")
        #expect(SpendDashboardSource.codexCacheRoot(for: second).lastPathComponent == "second-cache")
    }

    @Test
    func `cached Codex totals reject an account rotation during hydration`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardCachedAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let authURL = CodexAuthFingerprint.authFileURL(homePath: home.path)
        let originalAuth = Data("{\"profile\":\"owner-one\"}".utf8)
        try originalAuth.write(to: authURL, options: .atomic)
        let account = CodexSpendScanRequest(
            id: "account",
            displayName: "Codex",
            source: .profileHome(path: home.path),
            homePath: home.path,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: originalAuth),
            authFileWasReadable: true,
            cacheIdentity: "cached-auth")
        let request = SpendDashboardLoadRequest(
            configuration: Self.configuration(account: "account|cached-auth"),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: Self.fixtureNow,
            force: false)

        let result = await SpendDashboardSource.loadCached(request, cachedCodexSnapshotLoader: { _ in
            try? Data("{\"profile\":\"owner-two\"}".utf8).write(to: authURL, options: .atomic)
            return Self.input(cost: 9).snapshot
        })

        #expect(result.inputs.isEmpty)
    }

    private nonisolated static let fixtureNow = Date(timeIntervalSince1970: 1_784_179_200)

    private static func configuration(account: String) -> SpendDashboardConfiguration {
        SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [account])
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

    private nonisolated static func scanRequest(
        id: String,
        cacheIdentity: String) -> CodexSpendScanRequest
    {
        let homePath = "/synthetic/\(id)"
        return CodexSpendScanRequest(
            id: id,
            displayName: "Codex \(id)",
            source: .profileHome(path: homePath),
            homePath: homePath,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: cacheIdentity)
    }

    private nonisolated static func input(
        id: String? = nil,
        cost: Double,
        historyDays: Int = 30) -> SpendDashboardModel.ProviderInput
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
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
            historyDays: historyDays,
            daily: [entry],
            updatedAt: Self.fixtureNow)
        return SpendDashboardModel.ProviderInput(
            id: id,
            provider: .codex,
            displayName: "Codex",
            snapshot: snapshot)
    }

    private static func waitForPendingCount(_ count: Int, gate: SpendDashboardCachedLoaderGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) pending dashboard loads")
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
}

private actor SpendDashboardCachedLoaderGate {
    private var continuations: [CheckedContinuation<SpendDashboardLoadResult, Never>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        _ = request
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func resume(at index: Int, result: SpendDashboardLoadResult) {
        self.continuations.remove(at: index).resume(returning: result)
    }
}

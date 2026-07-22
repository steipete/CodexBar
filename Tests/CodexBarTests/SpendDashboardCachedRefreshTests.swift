import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardCachedRefreshTests {
    @Test
    func `cached dashboard data renders before request building and fresh loading finish`() async {
        let loaderGate = CachedRefreshLoaderGate()
        let requestGate = CachedRefreshRequestGate()
        let configuration = Self.configuration(account: "cached")
        let cachedInput = Self.input(cost: 3)
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                if mode == .refreshMissing {
                    await requestGate.suspend()
                }
                return Self.request(configuration: configuration, force: mode.forcesLoader)
            },
            cachedLoader: { _ in
                SpendDashboardLoadResult(inputs: [cachedInput], failedSourceIDs: [])
            },
            loader: { request in await loaderGate.load(request) })

        controller.update(configuration: configuration)
        await Self.waitForRequestGate(requestGate)

        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(controller.isRefreshing)
        #expect(await loaderGate.pendingCount == 0)

        await requestGate.resume()
        await Self.waitForPendingCount(1, gate: loaderGate)
        await loaderGate.resume(at: 0, result: .init(inputs: [Self.input(cost: 5)], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 5)
    }

    @Test
    func `replacement generation rejects stale priming cache completion`() async {
        let cachedGate = CachedRefreshResultGate()
        let loaderGate = CachedRefreshLoaderGate()
        let controllerBox = CachedRefreshControllerBox()
        let firstConfiguration = Self.configuration(account: "first")
        let secondConfiguration = Self.configuration(account: "second")
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                Self.request(
                    configuration: controllerBox.controller?.configuration ?? firstConfiguration,
                    force: mode.forcesLoader)
            },
            cachedLoader: { request in await cachedGate.load(request) },
            loader: { request in await loaderGate.load(request) })
        controllerBox.controller = controller

        controller.update(configuration: firstConfiguration)
        await Self.waitForCachedPendingCount(1, gate: cachedGate)
        controller.update(configuration: secondConfiguration)
        await Self.waitForCachedPendingCount(2, gate: cachedGate)

        await cachedGate.resume(
            at: 1,
            result: .init(inputs: [Self.input(cost: 2)], failedSourceIDs: []))
        await Self.waitForPendingCount(1, gate: loaderGate)
        await loaderGate.resume(
            at: 0,
            result: .init(inputs: [Self.input(cost: 3)], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        await cachedGate.resume(
            at: 0,
            result: .init(inputs: [Self.input(cost: 1)], failedSourceIDs: []))
        await Task.yield()
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(controller.generation == 3)
    }

    @Test
    func `cache miss stays refreshing through one fresh validation pass`() async {
        let loaderGate = CachedRefreshLoaderGate()
        let modeRecorder = CachedRefreshModeRecorder()
        let configuration = Self.configuration(account: "missing")
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                await modeRecorder.append(mode)
                return Self.request(configuration: configuration, force: mode.forcesLoader)
            },
            cachedLoader: { _ in SpendDashboardLoadResult(inputs: [], failedSourceIDs: []) },
            loader: { request in await loaderGate.load(request) })

        controller.update(configuration: configuration)
        await Self.waitForPendingCount(1, gate: loaderGate)

        #expect(controller.model.groups.isEmpty)
        #expect(controller.isRefreshing)
        #expect(await modeRecorder.values == [.captureOnly, .refreshMissing])

        await loaderGate.resume(at: 0, result: .init(inputs: [], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.isEmpty)
        #expect(await modeRecorder.values == [.captureOnly, .refreshMissing])
    }

    @Test
    func `cached dashboard data rejects auth rotation during hydration`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardCachedRefreshTests-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let authURL = CodexAuthFingerprint.authFileURL(homePath: home.path)
        let initialAuth = Data("{\"profile\":\"owner-one\"}".utf8)
        try initialAuth.write(to: authURL, options: .atomic)
        let account = CodexSpendScanRequest(
            id: "account",
            displayName: "Codex",
            source: .profileHome(path: home.path),
            homePath: home.path,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: initialAuth),
            authFileWasReadable: true,
            cacheIdentity: "cached-auth")
        let request = SpendDashboardLoadRequest(
            configuration: Self.configuration(account: "account|cached-auth"),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: false)
        let cachedSnapshot = Self.input(cost: 3).snapshot

        let result = await SpendDashboardSource.loadCached(request, cachedCodexSnapshotLoader: { _ in
            try? Data("{\"profile\":\"owner-two\"}".utf8).write(to: authURL, options: .atomic)
            return cachedSnapshot
        })

        #expect(result.inputs.isEmpty)
    }

    @Test
    func `cached dashboard reuses ambient root only for live system`() async {
        let liveAccount = CodexSpendScanRequest(
            id: "live",
            displayName: "Codex",
            source: .liveSystem,
            homePath: "/synthetic/live-codex-home",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "live-cache")
        let profileAccount = CodexSpendScanRequest(
            id: "profile",
            displayName: "Codex profile",
            source: .profileHome(path: "/synthetic/profile-codex-home"),
            homePath: "/synthetic/profile-codex-home",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "profile-cache")
        let request = SpendDashboardLoadRequest(
            configuration: Self.configuration(account: "live|live-cache,profile|profile-cache"),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [liveAccount, profileAccount],
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: false)
        let recorder = CachedRefreshCodexLoadRecorder()

        let result = await SpendDashboardSource.loadCached(request, cachedCodexSnapshotLoader: { context in
            await recorder.record(context)
            return nil
        })
        let contexts = await recorder.contexts

        #expect(result.inputs.isEmpty)
        #expect(contexts.map(\.cacheRoot) == [
            UsageStore.costUsageCacheDirectory().deletingLastPathComponent(),
            UsageStore.costUsageCacheDirectory()
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent("profile-cache", isDirectory: true),
        ])
    }

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
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: force)
    }

    private static func input(cost: Double) -> SpendDashboardModel.ProviderInput {
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
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
        return SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: UsageProvider.codex.rawValue,
            snapshot: snapshot)
    }

    private static func waitForRequestGate(_ gate: CachedRefreshRequestGate) async {
        for _ in 0..<1000 {
            if await gate.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for request builder")
    }

    private static func waitForCachedPendingCount(_ count: Int, gate: CachedRefreshResultGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) cached results")
    }

    private static func waitForPendingCount(_ count: Int, gate: CachedRefreshLoaderGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) pending loads")
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

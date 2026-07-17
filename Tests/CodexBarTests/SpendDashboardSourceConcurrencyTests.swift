import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardSourceConcurrencyTests {
    @Test
    func `Codex batch revalidates completed and failed accounts after later scans`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardSourceConcurrencyTests-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let completed = try Self.makeAccount(id: "completed", root: root)
        let failed = try Self.makeAccount(id: "failed", root: root)
        let later = try Self.makeAccount(id: "later", root: root)
        let completedSnapshot = Self.input(cost: 1).snapshot
        let laterSnapshot = Self.input(cost: 2).snapshot
        let gate = SpendDashboardCodexBatchGate()
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: [completed, failed, later].map { "\($0.id)|\($0.cacheIdentity)" }),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [completed, failed, later],
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: true)

        let loadTask = Task {
            await SpendDashboardSource.load(request, codexSnapshotLoader: { context in
                switch context.account.id {
                case completed.id:
                    completedSnapshot
                case failed.id:
                    throw SpendDashboardSyntheticError.failed
                default:
                    await gate.load()
                }
            })
        }
        await Self.waitForCodexGate(gate)
        let replacementAuth = Data("{\"profile\":\"replacement-owner\"}".utf8)
        try replacementAuth.write(
            to: CodexAuthFingerprint.authFileURL(homePath: completed.homePath),
            options: .atomic)
        try replacementAuth.write(
            to: CodexAuthFingerprint.authFileURL(homePath: failed.homePath),
            options: .atomic)
        await gate.resume(snapshot: laterSnapshot)

        let result = await loadTask.value
        #expect(result.inputs.map(\.id) == ["codex:later"])
        #expect(result.failedSourceIDs == ["codex:completed", "codex:failed"])
        #expect(result.invalidatedSourceIDs == ["codex:completed", "codex:failed"])
    }

    @Test
    func `Codex ownership change retains failed unchanged sibling only`() async {
        let gate = SpendDashboardResultBatchGate()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["a|owner-a", "b|owner-b"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["a|owner-a-replacement", "b|owner-b"])
        let requestSequence = SpendDashboardRequestSequence([
            .init(configuration: initial),
            .init(configuration: replacement),
        ])
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in await gate.load(request) })

        controller.update(configuration: initial)
        await Self.waitForResultGate(gate)
        await gate.resume(result: SpendDashboardLoadResult(
            inputs: [
                Self.input(id: "codex:a", cost: 3),
                Self.input(id: "codex:b", cost: 5),
            ],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 8)

        controller.update(configuration: replacement)
        await Self.waitForResultGate(gate)
        #expect(controller.model.groups.first?.totalCost == 5)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex:b"])
        await gate.resume(result: SpendDashboardLoadResult(
            inputs: [],
            failedSourceIDs: ["codex:a", "codex:b"]))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.totalCost == 5)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex:b"])
        #expect(controller.failedSourceCount == 2)
    }

    @Test
    func `Codex removal relabels retained failed account from second to first`() async throws {
        let gate = SpendDashboardResultBatchGate()
        let requestGate = SpendDashboardProviderBatchGate()
        let initialRequests = [
            Self.scanRequest(id: "a", displayName: "Codex · #1"),
            Self.scanRequest(id: "b", displayName: "Codex · #2"),
            Self.scanRequest(id: "c", displayName: "Codex · #3"),
        ]
        let replacementRequests = [
            Self.scanRequest(id: "b", displayName: "Codex · #1"),
            Self.scanRequest(id: "c", displayName: "Codex · #2"),
        ]
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["a|owner-a", "b|owner-b", "c|owner-c"],
            codexAccountDisplayNames: [
                "codex:a": "Codex · #1",
                "codex:b": "Codex · #2",
                "codex:c": "Codex · #3",
            ])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["b|owner-b", "c|owner-c"],
            codexAccountDisplayNames: [
                "codex:b": "Codex · #1",
                "codex:c": "Codex · #2",
            ])
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: initial, codexRequests: initialRequests),
                .init(configuration: replacement, codexRequests: replacementRequests),
            ],
            suspendAt: 1,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in await gate.load(request) })

        controller.update(configuration: initial)
        await Self.waitForResultGate(gate)
        await gate.resume(result: SpendDashboardLoadResult(
            inputs: [
                Self.input(id: "codex:a", cost: 3, displayName: "Codex · #1"),
                Self.input(id: "codex:b", cost: 5, displayName: "Codex · #2"),
                Self.input(id: "codex:c", cost: 7, displayName: "Codex · #3"),
            ],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.update(configuration: replacement)
        let pendingRows = try #require(controller.model.groups.first?.providers)
        #expect(Dictionary(uniqueKeysWithValues: pendingRows.map { ($0.id, $0.displayName) }) == [
            "codex:b": "Codex · #1",
            "codex:c": "Codex · #2",
        ])
        await Self.waitForProviderGate(requestGate)
        #expect(await gate.pendingCount == 0)
        await requestGate.resume()
        await Self.waitForResultGate(gate)
        await gate.resume(result: SpendDashboardLoadResult(
            inputs: [Self.input(id: "codex:c", cost: 8, displayName: "Codex · #2")],
            failedSourceIDs: ["codex:b"]))
        await Self.waitUntil { !controller.isRefreshing }

        let finalRows = try #require(controller.model.groups.first?.providers)
        #expect(Dictionary(uniqueKeysWithValues: finalRows.map { ($0.id, $0.displayName) }) == [
            "codex:b": "Codex · #1",
            "codex:c": "Codex · #2",
        ])
        #expect(finalRows.first { $0.id == "codex:b" }?.totalCost == 5)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `request revision captured before coalesced update cannot publish stale inputs`() async {
        let requestGate = SpendDashboardProviderBatchGate()
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            codexAccountIdentities: [],
            sourceOwnershipFingerprints: ["claude:owner"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            codexAccountIdentities: [],
            sourceOwnershipFingerprints: ["claude:owner"],
            sourceRevisions: ["R+1"])
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: initial, capturedInputs: [Self.input(provider: .claude, cost: 1)]),
                .init(configuration: replacement, capturedInputs: [Self.input(provider: .claude, cost: 2)]),
                .init(configuration: replacement, capturedInputs: [Self.input(provider: .claude, cost: 2)]),
            ],
            suspendAt: 0,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        await Self.waitForProviderGate(requestGate)
        controller.update(configuration: replacement)
        await requestGate.resume()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(requestSequence.modes == [.forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [initial])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `force adopts builder published revision without losing Codex scan intent`() async {
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner"],
            sourceRevisions: ["R+1"])
        let requestSequence = SpendDashboardRequestSequence([
            .init(configuration: replacement, capturedInputs: [Self.input(provider: .claude, cost: 2)]),
            .init(configuration: replacement, capturedInputs: [Self.input(provider: .claude, cost: 2)]),
        ])
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(requestSequence.modes == [.forceRefresh, .captureOnly])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `forced builder owner mismatch reruns replacement builder and rejects cached request`() async {
        let requestGate = SpendDashboardProviderBatchGate()
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner-one"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner-two"],
            sourceRevisions: ["R+1"])
        let cachedInput = Self.input(provider: .claude, cost: 1)
        let freshInput = Self.input(provider: .claude, cost: 3)
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: replacement, capturedInputs: [cachedInput]),
                .init(configuration: replacement, capturedInputs: [freshInput]),
                .init(configuration: replacement, capturedInputs: [freshInput]),
            ],
            suspendAt: 1,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        await Self.waitForProviderGate(requestGate)

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.isEmpty)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh])
        #expect(await recorder.configurations.isEmpty)

        await requestGate.resume()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [replacement])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `ownership replacement while force builder is pending reruns builder and loader forced`() async {
        let requestGate = SpendDashboardProviderBatchGate()
        let recorder = SpendDashboardRequestRecorder()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner-one"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner-two"],
            sourceRevisions: ["R+1"])
        let replacementInput = Self.input(provider: .codex, cost: 4)
        let requestSequence = SpendDashboardRequestSequence(
            [
                .init(configuration: initial, capturedInputs: [Self.input(provider: .codex, cost: 1)]),
                .init(configuration: replacement, capturedInputs: [replacementInput]),
                .init(configuration: replacement, capturedInputs: [replacementInput]),
            ],
            suspendAt: 0,
            gate: requestGate)
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in
                await recorder.record(request)
                return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })

        controller.update(configuration: initial, force: true)
        await Self.waitForProviderGate(requestGate)
        controller.update(configuration: replacement)
        await Self.waitUntil { !controller.isRefreshing }
        await requestGate.resume()
        await Task.yield()

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 4)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [replacement])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `ownership replacement after force builder completes reruns builder and loader forced`() async {
        let loaderGate = SpendDashboardRecordedResultGate()
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner-one"],
            sourceRevisions: ["R"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["account|owner"],
            sourceOwnershipFingerprints: ["claude:owner-two"],
            sourceRevisions: ["R+1"])
        let requestSequence = SpendDashboardRequestSequence([
            .init(configuration: initial),
            .init(configuration: replacement),
            .init(
                configuration: replacement,
                capturedInputs: [Self.input(provider: .codex, cost: 5)]),
        ])
        let controller = SpendDashboardController(
            requestBuilder: { mode in await requestSequence.next(mode: mode) },
            loader: { request in await loaderGate.load(request) })

        controller.update(configuration: initial, force: true)
        await Self.waitForRecordedResultGate(loaderGate, pendingCount: 1)
        controller.update(configuration: replacement)
        await Self.waitForRecordedResultGate(loaderGate, pendingCount: 2)

        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh])
        #expect(await loaderGate.configurations == [initial, replacement])
        #expect(await loaderGate.forces == [true, true])

        await loaderGate.resume(
            at: 1,
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .codex, cost: 5)],
                failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        await loaderGate.resume(
            at: 0,
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .codex, cost: 99)],
                failedSourceIDs: []))
        await Task.yield()

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 5)
    }

    @Test
    func `force request recaptures earlier provider after later refresh suspends`() async throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardSourceConcurrencyTests-force-recapture")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude || provider == .mistral)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let providers = SpendDashboardSource.costCapableProviders(store: store)
        #expect(providers == [.claude, .mistral])
        let firstProvider = UsageProvider.claude
        let laterProvider = UsageProvider.mistral
        store._setTokenSnapshotForTesting(
            Self.input(provider: firstProvider, cost: 1).snapshot,
            provider: firstProvider)
        store._setTokenSnapshotForTesting(
            Self.input(provider: laterProvider, cost: 2).snapshot,
            provider: laterProvider)

        let gate = SpendDashboardProviderBatchGate()
        store._test_tokenUsageRefreshOverride = { provider, _ in
            #expect(provider == firstProvider)
            store._setTokenSnapshotForTesting(
                Self.input(provider: provider, cost: 10).snapshot,
                provider: provider)
        }
        store._test_providerRefreshOverride = { provider in
            #expect(provider == laterProvider)
            await gate.suspend()
            store._setTokenSnapshotForTesting(
                Self.input(provider: provider, cost: 20).snapshot,
                provider: provider)
        }

        let requestTask = Task { @MainActor in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .forceRefresh)
        }
        await Self.waitForProviderGate(gate)
        store._setTokenSnapshotForTesting(
            Self.input(provider: firstProvider, cost: 11).snapshot,
            provider: firstProvider)
        await gate.resume()

        let request = await requestTask.value
        let firstInput = try #require(request.capturedInputs.first { $0.provider == firstProvider })
        let laterInput = try #require(request.capturedInputs.first { $0.provider == laterProvider })
        #expect(firstInput.snapshot.last30DaysCostUSD == 11)
        #expect(laterInput.snapshot.last30DaysCostUSD == 20)
        #expect(request.unavailableSourceIDs.isEmpty)
        #expect(request.configuration == SpendDashboardSource.configuration(settings: settings, store: store))
    }

    private static func makeAccount(id: String, root: URL) throws -> CodexSpendScanRequest {
        let home = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = Data("{\"profile\":\"\(id)-owner\"}".utf8)
        try auth.write(to: CodexAuthFingerprint.authFileURL(homePath: home.path), options: .atomic)
        return CodexSpendScanRequest(
            id: id,
            displayName: "Codex · \(id)",
            source: .profileHome(path: home.path),
            homePath: home.path,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: auth),
            authFileWasReadable: true,
            cacheIdentity: "\(id)-cache")
    }

    private static func scanRequest(id: String, displayName: String) -> CodexSpendScanRequest {
        CodexSpendScanRequest(
            id: id,
            displayName: displayName,
            source: .profileHome(path: "/synthetic/\(id)"),
            homePath: "/synthetic/\(id)",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "\(id)-cache")
    }

    private static func input(
        id: String? = nil,
        provider: UsageProvider = .codex,
        cost: Double,
        displayName: String? = nil) -> SpendDashboardModel.ProviderInput
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
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
        return SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: displayName ?? provider.rawValue,
            modelProviderName: provider == .codex ? "Codex" : nil,
            snapshot: snapshot)
    }

    private static func waitForCodexGate(_ gate: SpendDashboardCodexBatchGate) async {
        for _ in 0..<1000 {
            if await gate.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for pending Codex load")
    }

    private static func waitForProviderGate(_ gate: SpendDashboardProviderBatchGate) async {
        for _ in 0..<1000 {
            if await gate.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for pending provider refresh")
    }

    private static func waitForResultGate(_ gate: SpendDashboardResultBatchGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == 1 {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for pending dashboard load")
    }

    private static func waitForRecordedResultGate(
        _ gate: SpendDashboardRecordedResultGate,
        pendingCount: Int) async
    {
        for _ in 0..<1000 {
            if await gate.pendingCount == pendingCount {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(pendingCount) recorded dashboard loads")
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for dashboard state")
    }
}

private enum SpendDashboardSyntheticError: Error {
    case failed
}

@MainActor
private final class SpendDashboardRequestSequence {
    struct Item {
        let configuration: SpendDashboardConfiguration
        let capturedInputs: [SpendDashboardModel.ProviderInput]
        let codexRequests: [CodexSpendScanRequest]

        init(
            configuration: SpendDashboardConfiguration,
            capturedInputs: [SpendDashboardModel.ProviderInput] = [],
            codexRequests: [CodexSpendScanRequest] = [])
        {
            self.configuration = configuration
            self.capturedInputs = capturedInputs
            self.codexRequests = codexRequests
        }
    }

    private var items: [Item]
    private let suspendAt: Int?
    private let gate: SpendDashboardProviderBatchGate?
    private var index = 0
    private(set) var modes: [SpendDashboardRequestBuildMode] = []

    init(
        _ items: [Item],
        suspendAt: Int? = nil,
        gate: SpendDashboardProviderBatchGate? = nil)
    {
        self.items = items
        self.suspendAt = suspendAt
        self.gate = gate
    }

    func next(mode: SpendDashboardRequestBuildMode) async -> SpendDashboardLoadRequest {
        let item = self.items.removeFirst()
        let index = self.index
        self.index += 1
        self.modes.append(mode)
        if index == self.suspendAt {
            await self.gate?.suspend()
        }
        return SpendDashboardLoadRequest(
            configuration: item.configuration,
            capturedInputs: item.capturedInputs,
            unavailableSourceIDs: [],
            codexRequests: item.codexRequests,
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: mode.forcesLoader)
    }
}

private actor SpendDashboardRequestRecorder {
    private(set) var configurations: [SpendDashboardConfiguration] = []
    private(set) var forces: [Bool] = []

    func record(_ request: SpendDashboardLoadRequest) {
        self.configurations.append(request.configuration)
        self.forces.append(request.force)
    }
}

private actor SpendDashboardRecordedResultGate {
    private var requests: [SpendDashboardLoadRequest] = []
    private var continuations: [CheckedContinuation<SpendDashboardLoadResult, Never>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    var configurations: [SpendDashboardConfiguration] {
        self.requests.map(\.configuration)
    }

    var forces: [Bool] {
        self.requests.map(\.force)
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        self.requests.append(request)
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func resume(at index: Int, result: SpendDashboardLoadResult) {
        self.continuations.remove(at: index).resume(returning: result)
    }
}

private actor SpendDashboardCodexBatchGate {
    private var continuation: CheckedContinuation<CostUsageTokenSnapshot, Never>?

    var isSuspended: Bool {
        self.continuation != nil
    }

    func load() async -> CostUsageTokenSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(snapshot: CostUsageTokenSnapshot) {
        self.continuation?.resume(returning: snapshot)
        self.continuation = nil
    }
}

private actor SpendDashboardProviderBatchGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool {
        self.continuation != nil
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

private actor SpendDashboardResultBatchGate {
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

    func resume(result: SpendDashboardLoadResult) {
        self.continuations.removeFirst().resume(returning: result)
    }
}

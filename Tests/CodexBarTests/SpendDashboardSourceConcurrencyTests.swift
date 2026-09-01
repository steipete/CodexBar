import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardSourceConcurrencyTests {
    @Test
    func `gate readiness tolerates a delayed producer`() async throws {
        let gate = SpendDashboardPendingLoads<CostUsageTokenSnapshot>()
        defer { gate.close() }
        let producer = Task {
            try await Task.sleep(for: .seconds(2))
            return try await gate.load()
        }

        defer { producer.cancel() }
        try await gate.waitForPendingCount(1)
        #expect(gate.isSuspended)
        gate.resume(returning: Self.input(cost: 5).snapshot)
        let snapshot = try await producer.value
        #expect(snapshot.last30DaysCostUSD == 5)
    }

    @Test(CodexCredentialFixtures())
    func `Codex batch revalidates completed and failed accounts after later scans`() async throws {
        let root = CodexCredentialFixtures.root
            .appendingPathComponent("SpendDashboardSourceConcurrencyTests-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let completed = try Self.makeAccount(id: "completed", root: root)
        let failed = try Self.makeAccount(id: "failed", root: root)
        let later = try Self.makeAccount(id: "later", root: root)
        let completedSnapshot = Self.input(cost: 1).snapshot
        let laterSnapshot = Self.input(cost: 2).snapshot
        let gate = SpendDashboardPendingLoads<CostUsageTokenSnapshot>()
        defer { gate.close() }
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
                    try await gate.load()
                }
            })
        }
        defer { loadTask.cancel() }
        try await gate.waitForPendingCount(1)
        let replacementAuth = Data("{\"profile\":\"replacement-owner\"}".utf8)
        try replacementAuth.write(
            to: CodexAuthFingerprint.authFileURL(homePath: completed.homePath),
            options: .atomic)
        try replacementAuth.write(
            to: CodexAuthFingerprint.authFileURL(homePath: failed.homePath),
            options: .atomic)
        gate.resume(returning: laterSnapshot)

        let result = await loadTask.value
        #expect(result.inputs.map(\.id) == ["codex:later"])
        #expect(result.failedSourceIDs == ["codex:completed", "codex:failed"])
        #expect(result.invalidatedSourceIDs == ["codex:completed", "codex:failed"])
    }

    @Test
    func `Codex ownership change retains failed unchanged sibling only`() async throws {
        let gate = SpendDashboardResultBatchGate()
        defer { gate.close() }
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
        try await gate.waitForPendingCount(1)
        gate.resume(result: SpendDashboardLoadResult(
            inputs: [
                Self.input(id: "codex:a", cost: 3),
                Self.input(id: "codex:b", cost: 5),
            ],
            failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 8)

        controller.update(configuration: replacement)
        try await gate.waitForPendingCount(1)
        #expect(controller.model.groups.first?.totalCost == 5)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex:b"])
        gate.resume(result: SpendDashboardLoadResult(
            inputs: [],
            failedSourceIDs: ["codex:a", "codex:b"]))
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.totalCost == 5)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex:b"])
        #expect(controller.failedSourceCount == 2)
    }

    @Test
    func `Codex removal relabels retained failed account from second to first`() async throws {
        let gate = SpendDashboardResultBatchGate()
        defer { gate.close() }
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
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
        try await gate.waitForPendingCount(1)
        gate.resume(result: SpendDashboardLoadResult(
            inputs: [
                Self.input(id: "codex:a", cost: 3, displayName: "Codex · #1"),
                Self.input(id: "codex:b", cost: 5, displayName: "Codex · #2"),
                Self.input(id: "codex:c", cost: 7, displayName: "Codex · #3"),
            ],
            failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }

        controller.update(configuration: replacement)
        let pendingRows = try #require(controller.model.groups.first?.providers)
        #expect(Dictionary(uniqueKeysWithValues: pendingRows.map { ($0.id, $0.displayName) }) == [
            "codex:b": "Codex · #1",
            "codex:c": "Codex · #2",
        ])
        try await requestGate.waitForPendingCount(1)
        #expect(gate.pendingCount == 0)
        requestGate.resume()
        try await gate.waitForPendingCount(1)
        gate.resume(result: SpendDashboardLoadResult(
            inputs: [Self.input(id: "codex:c", cost: 8, displayName: "Codex · #2")],
            failedSourceIDs: ["codex:b"]))
        try await Self.waitUntil { !controller.isRefreshing }

        let finalRows = try #require(controller.model.groups.first?.providers)
        #expect(Dictionary(uniqueKeysWithValues: finalRows.map { ($0.id, $0.displayName) }) == [
            "codex:b": "Codex · #1",
            "codex:c": "Codex · #2",
        ])
        #expect(finalRows.first { $0.id == "codex:b" }?.totalCost == 5)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `request revision captured before coalesced update cannot publish stale inputs`() async throws {
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
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
        try await requestGate.waitForPendingCount(1)
        controller.update(configuration: replacement)
        requestGate.resume()
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(requestSequence.modes == [.forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [initial])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `force adopts builder published revision without losing Codex scan intent`() async throws {
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
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(requestSequence.modes == [.forceRefresh, .captureOnly])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `forced builder owner mismatch reruns replacement builder and rejects cached request`() async throws {
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
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
        try await requestGate.waitForPendingCount(1)

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.isEmpty)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh])
        #expect(await recorder.configurations.isEmpty)

        requestGate.resume()
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [replacement])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `ownership replacement while force builder is pending reruns builder and loader forced`() async throws {
        let requestGate = SpendDashboardPendingLoads<Void>()
        defer { requestGate.close() }
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
        try await requestGate.waitForPendingCount(1)
        controller.update(configuration: replacement)
        try await Self.waitUntil { !controller.isRefreshing }
        requestGate.resume()
        await Task.yield()

        #expect(controller.configuration == replacement)
        #expect(controller.generation == 3)
        #expect(controller.model.groups.first?.totalCost == 4)
        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh, .captureOnly])
        #expect(await recorder.configurations == [replacement])
        #expect(await recorder.forces == [true])
    }

    @Test
    func `ownership replacement after force builder completes reruns builder and loader forced`() async throws {
        let loaderGate = SpendDashboardResultBatchGate()
        defer { loaderGate.close() }
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
        try await loaderGate.waitForPendingCount(1)
        controller.update(configuration: replacement)
        try await loaderGate.waitForPendingCount(2)

        #expect(requestSequence.modes == [.forceRefresh, .forceRefresh])
        #expect(loaderGate.configurations == [initial, replacement])
        #expect(loaderGate.forces == [true, true])

        loaderGate.resume(
            at: 1,
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .codex, cost: 5)],
                failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }
        loaderGate.resume(
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
    func `ordinary in flight same owner revision churn does not restart load`() async throws {
        let loaderGate = SpendDashboardResultBatchGate()
        defer { loaderGate.close() }
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["same"],
            sourceRevisions: ["first"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["same"],
            sourceRevisions: ["second"])
        let controllerBox = SpendDashboardControllerBox()
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                let configuration = controllerBox.controller?.configuration ?? initial
                return SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            loader: { request in await loaderGate.load(request) })
        controllerBox.controller = controller

        controller.update(configuration: initial)
        try await loaderGate.waitForPendingCount(1)
        let inFlightGeneration = controller.generation
        #expect(controller.isRefreshing)

        controller.update(configuration: replacement)
        #expect(controller.generation == inFlightGeneration)
        #expect(controller.configuration == replacement)
        #expect(controller.publication.configuration == replacement)
        #expect(controller.publication.isRefreshing)

        loaderGate.resume(
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .codex, cost: 7)],
                failedSourceIDs: []))
        try await loaderGate.waitForPendingCount(1)
        loaderGate.resume(
            result: SpendDashboardLoadResult(
                inputs: [Self.input(provider: .codex, cost: 7)],
                failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.generation == inFlightGeneration + 1)
        #expect(controller.configuration == replacement)
        #expect(controller.model.groups.first?.totalCost == 7)
    }

    @Test
    func `ordinary in flight same owner revision churn preserves live load after suspended cached prefill`()
        async throws
    {
        let cachedGate = SpendDashboardResultBatchGate()
        defer { cachedGate.close() }
        let loaderGate = SpendDashboardResultBatchGate()
        defer { loaderGate.close() }
        let initial = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["same|owner-same"],
            sourceRevisions: ["first"])
        let replacement = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["same|owner-same"],
            sourceRevisions: ["second"])
        let controllerBox = SpendDashboardControllerBox()
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                let configuration = controllerBox.controller?.configuration ?? initial
                return SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [Self.scanRequest(id: "same", displayName: "Codex")],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            cachedLoader: { request in await cachedGate.load(request) },
            loader: { request in await loaderGate.load(request) })
        controllerBox.controller = controller

        controller.update(configuration: initial)
        try await cachedGate.waitForPendingCount(1)
        let inFlightGeneration = controller.generation
        #expect(controller.isRefreshing)

        // Revision churn arrives while cached prefill is suspended.
        controller.update(configuration: replacement)
        #expect(controller.generation == inFlightGeneration)
        #expect(controller.configuration == replacement)

        // Resume cached prefill with stale initial configuration result.
        cachedGate.resume(
            result: SpendDashboardLoadResult(
                inputs: [Self.input(id: "codex:same", cost: 3)],
                failedSourceIDs: []))

        // Ensure live load is still executed rather than aborting the task early.
        try await loaderGate.waitForPendingCount(1)
        loaderGate.resume(
            result: SpendDashboardLoadResult(
                inputs: [Self.input(id: "codex:same", cost: 12)],
                failedSourceIDs: []))

        // Reconciliation pass for remaining drift if needed.
        try await Self.waitUntil { !controller.isRefreshing || loaderGate.pendingCount > 0 }
        if loaderGate.pendingCount > 0 {
            loaderGate.resume(
                result: SpendDashboardLoadResult(
                    inputs: [Self.input(id: "codex:same", cost: 12)],
                    failedSourceIDs: []))
        }

        try await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.configuration == replacement)
        #expect(controller.model.groups.first?.totalCost == 12)
    }

    @Test(CodexCredentialFixtures())
    func `Codex concurrent loads restore configured order when completing out of order`() async throws {
        let root = CodexCredentialFixtures.root
            .appendingPathComponent(
                "SpendDashboardSourceConcurrencyTests-order-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try Self.makeAccount(id: "first", root: root)
        let second = try Self.makeAccount(id: "second", root: root)
        // Equal cost so providerRows tie-breaker is input order, making completion order visible.
        let firstSnapshot = Self.input(cost: 5).snapshot
        let secondSnapshot = Self.input(cost: 5).snapshot
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: [first, second].map { "\($0.id)|\($0.cacheIdentity)" }),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [first, second],
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: true)

        let secondSnapshotLoaded = SpendDashboardTestSignal<Void>()
        let gateFirst = SpendDashboardPendingLoads<CostUsageTokenSnapshot>()
        defer { gateFirst.close() }
        let gateSecond = SpendDashboardPendingLoads<CostUsageTokenSnapshot>()
        defer { gateSecond.close() }
        let loadTask = Task {
            await SpendDashboardSource.load(
                request,
                codexSnapshotLoader: { context in
                    switch context.account.id {
                    case first.id:
                        try await gateFirst.load()
                    case second.id:
                        try await gateSecond.load()
                    default:
                        fatalError("unexpected account \(context.account.id)")
                    }
                },
                codexActivityLoader: { context in
                    if context.account.id == second.id {
                        await secondSnapshotLoaded.resolve(.success(()))
                    }
                    return nil
                })
        }
        defer { loadTask.cancel() }
        // Wait until both gates are suspended, then resume second before first.
        try await gateFirst.waitForPendingCount(1)
        try await gateSecond.waitForPendingCount(1)
        gateSecond.resume(returning: secondSnapshot)
        // Activity loading follows snapshot loading; first must still be blocked at that boundary.
        try await secondSnapshotLoaded.wait()
        #expect(gateFirst.isSuspended)
        gateFirst.resume(returning: firstSnapshot)
        let final = await loadTask.value
        // Inputs should be in configured order [first, second], not completion order.
        #expect(final.inputs.map(\.id) == ["codex:first", "codex:second"])
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

        let gate = SpendDashboardPendingLoads<Void>()
        defer { gate.close() }
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
        defer { requestTask.cancel() }
        try await gate.waitForPendingCount(1)
        store._setTokenSnapshotForTesting(
            Self.input(provider: firstProvider, cost: 11).snapshot,
            provider: firstProvider)
        gate.resume()

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

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        try await SpendDashboardStateWait.until(condition)
    }
}

extension SpendDashboardSourceConcurrencyTests {
    @Test
    func `gate readiness observes an already pending producer and can be reused`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        for value in [1, 2] {
            let producer = Task { try await gate.load() }
            try await Self.waitUntil { gate.pendingCount == 1 }
            try await gate.waitForPendingCount(1)
            #expect(gate.readinessWaiterCount == 0)
            gate.resume(returning: value)
            #expect(try await producer.value == value)
            #expect(gate.pendingCount == 0)
        }
    }

    @Test
    func `gate readiness timeout drains pending loads and rejects late arrivals`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let producer = Task { try await gate.load() }
        try await gate.waitForPendingCount(1)

        let started = ContinuousClock.now
        await #expect(throws: SpendDashboardWaitError.timedOut) {
            try await gate.waitForPendingCount(2, timeout: .milliseconds(20))
        }
        #expect(ContinuousClock.now - started >= .milliseconds(20))
        await #expect(throws: SpendDashboardWaitError.closed) { try await producer.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await gate.load() }
        #expect(gate.isClosed)
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `cancelling a registered readiness wait drains its producer`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let producer = Task { try await gate.load() }
        try await gate.waitForPendingCount(1)
        let waiter = Task { try await gate.waitForPendingCount(2) }
        try await Self.waitUntil { gate.readinessWaiterCount == 1 }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await producer.value }
        #expect(gate.isClosed)
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `readiness cancellation before registration closes the gate`() async {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let waiter = Task { try await gate.waitForPendingCount(1) }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await gate.load() }
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `producer cancellation preserves the deliberate stale completion gate`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        defer { gate.close() }
        let producer = Task { try await gate.load() }
        try await gate.waitForPendingCount(1)
        producer.cancel()
        #expect(gate.pendingCount == 1)
        gate.resume(returning: 42)
        #expect(try await producer.value == 42)
        #expect(gate.pendingCount == 0)
    }

    @Test
    func `throwing test scope drains multiple pending loads`() async throws {
        let gate = SpendDashboardPendingLoads<Int>()
        let first = Task { try await gate.load() }
        let second = Task { try await gate.load() }
        await #expect(throws: SpendDashboardSyntheticError.failed) {
            defer { gate.close() }
            try await gate.waitForPendingCount(2)
            throw SpendDashboardSyntheticError.failed
        }

        await #expect(throws: SpendDashboardWaitError.closed) { try await first.value }
        await #expect(throws: SpendDashboardWaitError.closed) { try await second.value }
        gate.close()
        #expect(gate.pendingCount == 0)
        #expect(gate.readinessWaiterCount == 0)
    }

    @Test
    func `state observation timeout releases its captured state`() async {
        weak var released: SpendDashboardPendingLoads<Int>?
        await #expect(throws: SpendDashboardWaitError.timedOut) {
            let gate = SpendDashboardPendingLoads<Int>()
            released = gate
            try await SpendDashboardStateWait.until(timeout: .milliseconds(20)) {
                gate.isClosed
            }
        }
        #expect(released == nil)
    }
}

private enum SpendDashboardSyntheticError: Error, Equatable {
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
    private let gate: SpendDashboardPendingLoads<Void>?
    private var index = 0
    private(set) var modes: [SpendDashboardRequestBuildMode] = []

    init(
        _ items: [Item],
        suspendAt: Int? = nil,
        gate: SpendDashboardPendingLoads<Void>? = nil)
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

private enum SpendDashboardWaitError: Error, Equatable {
    case timedOut
    case closed
}

@MainActor
private final class SpendDashboardTestSignal<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var watchdog: Task<Void, Never>?

    func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        self.watchdog?.cancel()
        self.watchdog = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func wait(timeout: Duration = .seconds(5), ignoringCancellation: Bool = false) async throws -> Value {
        try await withTaskCancellationHandler {
            if !ignoringCancellation {
                try Task.checkCancellation()
            }
            if let result = self.result {
                return try result.get()
            }
            let deadline = ContinuousClock.now + timeout
            return try await withCheckedThrowingContinuation { continuation in
                precondition(self.continuation == nil)
                self.continuation = continuation
                self.watchdog = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    self?.resolve(.failure(SpendDashboardWaitError.timedOut))
                }
            }
        } onCancel: {
            if !ignoringCancellation {
                Task { @MainActor in self.resolve(.failure(CancellationError())) }
            }
        }
    }
}

@MainActor
final class SpendDashboardStateWait {
    private var condition: (@MainActor () -> Bool)?
    private let signal = SpendDashboardTestSignal<Void>()

    private init(_ condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
    }

    static func until(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool) async throws
    {
        let wait = Self(condition)
        defer { wait.condition = nil }
        wait.observe()
        try await wait.signal.wait(timeout: timeout)
    }

    private func observe() {
        guard let condition = self.condition else { return }
        if withObservationTracking(condition, onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }) {
            self.signal.resolve(.success(()))
        }
    }
}

@MainActor
@Observable
final class SpendDashboardPendingLoads<Value: Sendable> {
    private var pending: [SpendDashboardTestSignal<Value>] = []
    private(set) var isClosed = false
    private(set) var readinessWaiterCount = 0

    var pendingCount: Int {
        self.pending.count
    }

    var isSuspended: Bool {
        !self.pending.isEmpty
    }

    func load() async throws -> Value {
        guard !self.isClosed else { throw SpendDashboardWaitError.closed }
        let signal = SpendDashboardTestSignal<Value>()
        self.pending.append(signal)
        defer { self.pending.removeAll { $0 === signal } }
        do {
            // Stale-owner tests deliberately complete cancelled producers. Only the test owns their release.
            return try await signal.wait(ignoringCancellation: true)
        } catch {
            if case SpendDashboardWaitError.timedOut = error {
                Issue.record("Timed out waiting for the test to release a dashboard load")
            }
            self.close()
            throw error
        }
    }

    func waitForPendingCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        self.readinessWaiterCount += 1
        defer { self.readinessWaiterCount -= 1 }
        do {
            try await SpendDashboardStateWait.until(timeout: timeout) {
                self.pendingCount == count || self.isClosed
            }
            guard !self.isClosed else { throw SpendDashboardWaitError.closed }
        } catch {
            self.close()
            throw error
        }
    }

    func resume(at index: Int = 0, returning value: Value) {
        guard self.pending.indices.contains(index) else {
            Issue.record("Cannot resume a dashboard load before it is pending")
            return
        }
        self.pending.remove(at: index).resolve(.success(value))
    }

    func close() {
        self.isClosed = true
        let pending = self.pending
        self.pending.removeAll()
        for signal in pending {
            signal.resolve(.failure(SpendDashboardWaitError.closed))
        }
    }
}

extension SpendDashboardPendingLoads where Value == Void {
    func suspend() async {
        _ = try? await self.load()
    }

    func resume() {
        self.resume(returning: ())
    }
}

@MainActor
private final class SpendDashboardResultBatchGate {
    private var requests: [SpendDashboardLoadRequest] = []
    private let pending = SpendDashboardPendingLoads<SpendDashboardLoadResult>()

    var pendingCount: Int {
        self.pending.pendingCount
    }

    var configurations: [SpendDashboardConfiguration] {
        self.requests.map(\.configuration)
    }

    var forces: [Bool] {
        self.requests.map(\.force)
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        self.requests.append(request)
        do {
            return try await self.pending.load()
        } catch {
            // A readiness failure already fails the test; closing its scope must still drain controller tasks.
            return SpendDashboardLoadResult(inputs: [], failedSourceIDs: [])
        }
    }

    func waitForPendingCount(_ count: Int) async throws {
        try await self.pending.waitForPendingCount(count)
    }

    func resume(at index: Int = 0, result: SpendDashboardLoadResult) {
        self.pending.resume(at: index, returning: result)
    }

    func close() {
        self.pending.close()
    }
}

@MainActor
private final class SpendDashboardControllerBox {
    var controller: SpendDashboardController?
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardControllerTests {
    @Test
    func `empty codex history loads as successful inactive source`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let recorder = SpendDashboardCodexLoadRecorder()
        let account = CodexSpendScanRequest(
            id: "inactive",
            displayName: "Codex",
            source: .profileHome(path: "/synthetic/codex-home"),
            homePath: "/synthetic/codex-home",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "inactive-cache")
        let request = SpendDashboardLoadRequest(
            configuration: Self.configuration(account: "inactive|inactive-cache"),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: now,
            force: false)

        let result = await SpendDashboardSource.load(request, codexSnapshotLoader: { context in
            await recorder.record(context)
            return CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: 0,
                historyDays: context.historyDays,
                daily: [],
                updatedAt: context.now)
        })
        let contexts = await recorder.contexts

        #expect(result.inputs.count == 1)
        #expect(result.inputs.first?.id == "codex:inactive")
        #expect(result.inputs.first?.snapshot.daily.isEmpty == true)
        #expect(result.failedSourceIDs.isEmpty)
        #expect(contexts.count == 1)
        #expect(contexts.first?.account == account)
        #expect(contexts.first?.cacheRoot.lastPathComponent == "inactive-cache")
        #expect(contexts.first?.now == now)
        #expect(contexts.first?.force == false)
        #expect(contexts.first?.historyDays == 30)
        #expect(contexts.first?.refreshPricingInBackground == false)
        #expect(contexts.first?.includePiSessions == false)
    }

    @Test
    func `Codex auth rotation invalidates stale spend while retaining unrelated providers`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SpendDashboardControllerTests-auth-rotation-\(UUID().uuidString)",
                isDirectory: true)
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
            cacheIdentity: "auth-rotation")
        let gate = SpendDashboardCodexSnapshotGate()
        let recorder = SpendDashboardLoadResultRecorder()
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.openai.rawValue],
            codexAccountIdentities: ["account|auth-rotation"],
            codexAccountDisplayNames: ["codex:account": "Codex"],
            sourceOwnershipFingerprints: ["openai:stable"])
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [Self.input(id: "openai", provider: .openai, cost: 2)],
                    unavailableSourceIDs: [],
                    codexRequests: [account],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            loader: { request in
                let result = await SpendDashboardSource.load(request, codexSnapshotLoader: { context in
                    await gate.load(context)
                })
                await recorder.record(result)
                return result
            })

        controller.update(configuration: configuration)
        await Self.waitForCodexPendingCount(1, gate: gate)
        await gate.resume(at: 0, snapshot: Self.input(cost: 6).snapshot)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 8)

        controller.refresh()
        await Self.waitForCodexPendingCount(1, gate: gate)
        let replacementAuth = Data("{\"profile\":\"owner-two\"}".utf8)
        try replacementAuth.write(to: authURL, options: .atomic)
        await gate.resume(at: 0, snapshot: Self.input(cost: 99).snapshot)
        await Self.waitUntil { !controller.isRefreshing }

        let results = await recorder.results
        #expect(results.last?.invalidatedSourceIDs == ["codex:account"])
        #expect(results.last?.failedSourceIDs == ["codex:account"])
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["openai"])
    }

    @Test
    func `replacement generation rejects stale completion`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)
        let firstConfiguration = Self.configuration(account: "first")
        let secondConfiguration = Self.configuration(account: "second")

        controller.update(configuration: firstConfiguration)
        await Self.waitForPendingCount(1, gate: gate)
        controller.update(configuration: secondConfiguration)
        await Self.waitForPendingCount(2, gate: gate)

        await gate.resume(at: 1, result: .init(inputs: [Self.input(cost: 2)], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(controller.generation == 2)

        await gate.resume(at: 0, result: .init(inputs: [Self.input(cost: 1)], failedSourceIDs: []))
        await Task.yield()
        #expect(controller.model.groups.first?.totalCost == 2)
    }

    @Test
    func `failed same configuration refresh retains last good model`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)
        let configuration = Self.configuration(account: "same")

        controller.update(configuration: configuration)
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(
            inputs: [
                Self.input(cost: 7),
                Self.input(id: "claude", provider: .claude, cost: 3),
            ],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 10)

        controller.refresh()
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(inputs: [Self.input(cost: 8)], failedSourceIDs: ["claude"]))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 11)
        #expect(controller.model.groups.first?.providers.count == 2)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `refresh retains only sources that actually failed`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)
        let configuration = Self.configuration(account: "same")

        controller.update(configuration: configuration)
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(
            inputs: [
                Self.input(cost: 7),
                Self.input(id: "claude", provider: .claude, cost: 3),
                Self.input(id: "openai", provider: .openai, cost: 2),
            ],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(
            inputs: [Self.input(cost: 8)],
            failedSourceIDs: ["claude"]))
        await Self.waitUntil { !controller.isRefreshing }

        let providerIDs = Set(controller.model.groups.flatMap(\.providers).map(\.id))
        #expect(providerIDs == ["codex", "claude"])
        #expect(controller.model.groups.first?.totalCost == 11)
    }

    @Test
    func `changed data revision retains failed source with same ownership`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)

        controller.update(configuration: Self.configuration(account: "same", revision: "first"))
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(
            inputs: [
                Self.input(cost: 7),
                Self.input(id: "claude", provider: .claude, cost: 3),
            ],
            failedSourceIDs: ["openai"]))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.failedSourceCount == 1)

        controller.update(configuration: Self.configuration(account: "same", revision: "second"))
        await Self.waitForPendingCount(1, gate: gate)
        #expect(controller.isRefreshing)
        #expect(controller.model.groups.first?.totalCost == 10)
        #expect(controller.failedSourceCount == 1)
        await gate.resume(at: 0, result: .init(
            inputs: [Self.input(cost: 8)],
            failedSourceIDs: ["claude"]))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.totalCost == 11)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex", "claude"])
    }

    @Test
    func `snapshot spend replacement with unchanged metadata triggers reload`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)
        let firstInput = Self.input(provider: .claude, cost: 3)
        let replacementInput = Self.input(provider: .claude, cost: 8)
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-snapshot-replacement")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        store._setTokenSnapshotForTesting(firstInput.snapshot, provider: .claude)
        let firstConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        store._setTokenSnapshotForTesting(replacementInput.snapshot, provider: .claude)
        let replacementConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)

        #expect(firstInput.snapshot.daily.count == replacementInput.snapshot.daily.count)
        #expect(firstInput.snapshot.updatedAt == replacementInput.snapshot.updatedAt)
        #expect(firstInput.snapshot.historyDays == replacementInput.snapshot.historyDays)
        #expect(firstConfiguration.providerIDs == [UsageProvider.claude.rawValue])
        #expect(firstConfiguration.sourceRevisions != replacementConfiguration.sourceRevisions)

        controller.update(configuration: firstConfiguration)
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(inputs: [firstInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 3)

        controller.update(configuration: replacementConfiguration)
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(inputs: [replacementInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 8)
    }

    @Test
    func `identical successful republication reloads and clears retained failure warning`() async {
        let settings = testSettingsStore(
            suiteName: "SpendDashboardControllerTests-identical-republication")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let snapshot = Self.input(id: "claude", provider: .claude, cost: 3).snapshot
        store._setTokenSnapshotForTesting(snapshot, provider: .claude)
        store._test_tokenUsageRefreshOverride = { _, _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })

        let baselineConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        controller.update(configuration: baselineConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 3)

        controller.refresh()
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(controller.failedSourceCount == 1)

        store._setTokenSnapshotForTesting(snapshot, provider: .claude)
        let replacementConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(replacementConfiguration.sourceRevisions != baselineConfiguration.sourceRevisions)
        controller.update(configuration: replacementConfiguration)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.generation == 4)
        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(controller.failedSourceCount == 0)

        let settledGeneration = controller.generation
        controller.update(configuration: replacementConfiguration)
        await Task.yield()
        #expect(controller.generation == settledGeneration)
    }

    @Test
    func `capture request distinguishes confirmed empty provider from unavailable provider`() async {
        let settings = testSettingsStore(
            suiteName: "SpendDashboardControllerTests-confirmed-empty-capture")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.publishConfirmedEmptyTokenSnapshot(for: .claude)

        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly)

        #expect(request.capturedInputs.isEmpty)
        #expect(request.unavailableSourceIDs.isEmpty)
        #expect(request.confirmedEmptySourceIDs == [UsageProvider.claude.rawValue])
    }

    @Test
    func `changed provider ownership drops only stale source and retains unchanged failures`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)
        let firstConfiguration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex", "claude", "openai"],
            codexAccountIdentities: ["same|cache"],
            sourceOwnershipFingerprints: ["claude:owner-one", "openai:owner"],
            sourceRevisions: ["first"])
        let replacementConfiguration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex", "claude", "openai"],
            codexAccountIdentities: ["same|cache"],
            sourceOwnershipFingerprints: ["claude:owner-two", "openai:owner"],
            sourceRevisions: ["second"])

        controller.update(configuration: firstConfiguration)
        await Self.waitForPendingCount(1, gate: gate)
        await gate.resume(at: 0, result: .init(
            inputs: [
                Self.input(cost: 7),
                Self.input(id: "claude", provider: .claude, cost: 3),
                Self.input(id: "openai", provider: .openai, cost: 2),
            ],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.update(configuration: replacementConfiguration)
        await Self.waitForPendingCount(1, gate: gate)
        #expect(controller.isRefreshing)
        #expect(controller.model.groups.first?.totalCost == 9)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex", "openai"])
        #expect(controller.failedSourceCount == 0)
        await gate.resume(at: 0, result: .init(
            inputs: [Self.input(cost: 8)],
            failedSourceIDs: ["claude", "openai"]))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.totalCost == 10)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["codex", "openai"])
        #expect(controller.failedSourceCount == 2)
    }

    @Test
    func `changed provider ownership requires a confirmed fresh store snapshot`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-owner-freshness")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        settings.updateProviderConfig(provider: .claude) { config in
            config.enterpriseHost = "owner-one.invalid"
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setTokenSnapshotForTesting(Self.input(provider: .claude, cost: 3).snapshot, provider: .claude)
        store._test_tokenUsageRefreshOverride = { _, _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })

        let firstConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        controller.update(configuration: firstConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 3)

        settings.updateProviderConfig(provider: .claude) { config in
            config.enterpriseHost = "owner-two.invalid"
        }
        let replacementConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(firstConfiguration.sourceOwnershipFingerprints != replacementConfiguration.sourceOwnershipFingerprints)

        controller.update(configuration: replacementConfiguration)
        #expect(controller.model.groups.isEmpty)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 1)
        #expect(store.tokenSnapshot(for: .claude)?.last30DaysCostUSD == 3)

        let reopenedController = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        reopenedController.update(configuration: replacementConfiguration)
        await Self.waitUntil { !reopenedController.isRefreshing }
        #expect(reopenedController.model.groups.isEmpty)
        #expect(reopenedController.failedSourceCount == 1)

        let identicalSnapshot = store.tokenSnapshot(for: .claude)
        store._test_tokenUsageRefreshOverride = { provider, _ in
            guard provider == .claude, let identicalSnapshot else { return }
            store._setTokenSnapshotForTesting(identicalSnapshot, provider: provider)
        }
        settings.updateProviderConfig(provider: .claude) { config in
            config.enterpriseHost = "owner-three.invalid"
        }
        let thirdConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        reopenedController.update(configuration: thirdConfiguration)
        await Self.waitUntil { !reopenedController.isRefreshing }
        #expect(reopenedController.model.groups.first?.totalCost == 3)
        #expect(reopenedController.failedSourceCount == 0)
    }

    @Test
    func `selected token account ownership ignores inactive edits and drops failed replacement`() async throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-token-account-owner")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .mistral)
        }
        settings.addTokenAccount(provider: .mistral, label: "Primary", token: UUID().uuidString)
        settings.addTokenAccount(provider: .mistral, label: "Backup", token: UUID().uuidString)
        settings.setActiveTokenAccountIndex(0, for: .mistral)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let primaryConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        let accounts = settings.tokenAccounts(for: .mistral)
        let backup = try #require(accounts.last)
        settings.updateTokenAccount(provider: .mistral, accountID: backup.id, label: "Renamed backup")
        let inactiveEditConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(primaryConfiguration.sourceOwnershipFingerprints == inactiveEditConfiguration
            .sourceOwnershipFingerprints)

        settings.setActiveTokenAccountIndex(1, for: .mistral)
        let selectedBackupConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(inactiveEditConfiguration.sourceOwnershipFingerprints != selectedBackupConfiguration
            .sourceOwnershipFingerprints)

        store._setTokenSnapshotForTesting(Self.input(provider: .mistral, cost: 3).snapshot, provider: .mistral)
        store._test_providerRefreshOverride = { _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        controller.update(configuration: selectedBackupConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 3)

        let selectedBackup = try #require(settings.effectiveSelectedTokenAccount(for: .mistral))
        settings.updateTokenAccount(
            provider: .mistral,
            accountID: selectedBackup.id,
            token: UUID().uuidString)
        let replacementConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(selectedBackupConfiguration.sourceOwnershipFingerprints != replacementConfiguration
            .sourceOwnershipFingerprints)

        controller.update(configuration: replacementConfiguration)
        #expect(controller.model.groups.isEmpty)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `ordinary force failure retains same owner last good snapshot with warning`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-force-failure")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setTokenSnapshotForTesting(Self.input(provider: .claude, cost: 4).snapshot, provider: .claude)
        store._test_tokenUsageRefreshOverride = { _, _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 4)

        controller.refresh()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.totalCost == 4)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `history scope change drops stale spend when replacement refresh is unconfirmed`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-history-scope")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setTokenSnapshotForTesting(Self.input(provider: .claude, cost: 5).snapshot, provider: .claude)
        store._test_tokenUsageRefreshOverride = { _, _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        let firstConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        controller.update(configuration: firstConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 5)

        settings.costUsageHistoryDays = 7
        let replacementConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(firstConfiguration.sourceOwnershipFingerprints != replacementConfiguration.sourceOwnershipFingerprints)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .claude) == nil)

        controller.update(configuration: replacementConfiguration)
        #expect(controller.model.groups.isEmpty)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `Vertex spend ownership includes Claude fallback enablement`() {
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-vertex-scope")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .vertexai)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setTokenSnapshotForTesting(Self.input(provider: .vertexai, cost: 6).snapshot, provider: .vertexai)
        let firstConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        let firstVertexOwnership = firstConfiguration.sourceOwnershipFingerprints.first {
            $0.hasPrefix("vertexai:")
        }
        #expect(firstVertexOwnership != nil)

        if let claudeMetadata = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        }
        let replacementConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        let replacementVertexOwnership = replacementConfiguration.sourceOwnershipFingerprints.first {
            $0.hasPrefix("vertexai:")
        }

        #expect(firstVertexOwnership != replacementVertexOwnership)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .vertexai) == nil)
    }

    @Test
    func `cost tracking disable and reenable cannot revive the prior snapshot`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardControllerTests-cost-enable-epoch")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setTokenSnapshotForTesting(Self.input(provider: .claude, cost: 5).snapshot, provider: .claude)
        store._test_tokenUsageRefreshOverride = { _, _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 5)

        settings.costUsageEnabled = false
        controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
        #expect(controller.model.groups.isEmpty)
        settings.costUsageEnabled = true
        let reenabledConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .claude) == nil)
        controller.update(configuration: reenabledConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 1)

        let reopenedController = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        reopenedController.update(configuration: reenabledConfiguration)
        await Self.waitUntil { !reopenedController.isRefreshing }
        #expect(reopenedController.model.groups.isEmpty)
        #expect(reopenedController.failedSourceCount == 1)
    }

    @Test
    func `force refresh coalesces volatile revisions and finishes every provider`() async {
        let controllerBox = SpendDashboardControllerBox()
        let refreshRecorder = SpendDashboardRefreshRecorder()
        let initialConfiguration = Self.configuration(account: "same", revision: "initial")
        let firstProviderConfiguration = Self.configuration(account: "same", revision: "claude-fresh")
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                if mode == .forceRefresh {
                    await refreshRecorder.append(.claude)
                    controllerBox.controller?.update(configuration: firstProviderConfiguration)
                    await refreshRecorder.append(.openai)
                }
                return SpendDashboardLoadRequest(
                    configuration: firstProviderConfiguration,
                    capturedInputs: [
                        Self.input(id: "claude", provider: .claude, cost: 3),
                        Self.input(id: "openai", provider: .openai, cost: 4),
                    ],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            loader: { request in
                SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            })
        controllerBox.controller = controller

        controller.update(configuration: initialConfiguration, force: true)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(await refreshRecorder.providers == [.claude, .openai])
        #expect(controller.configuration == firstProviderConfiguration)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 7)
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["claude", "openai"])
    }

    @Test
    func `force refresh reconciles loader drift through capture barrier without second loader`() async {
        let gate = SpendDashboardLoaderGate()
        let forceRecorder = SpendDashboardForceRecorder()
        let initialConfiguration = Self.configuration(account: "same", revision: "initial")
        let latestConfiguration = Self.configuration(account: "same", revision: "latest")
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                await forceRecorder.append(mode)
                if mode == .forceRefresh {
                    return Self.request(configuration: initialConfiguration, force: true)
                }
                return SpendDashboardLoadRequest(
                    configuration: latestConfiguration,
                    capturedInputs: [Self.input(id: "claude", provider: .claude, cost: 2)],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: false)
            },
            loader: { request in await gate.load(request) })

        controller.update(configuration: initialConfiguration, force: true)
        await Self.waitForPendingCount(1, gate: gate)
        controller.update(configuration: latestConfiguration)
        await gate.resume(at: 0, result: .init(inputs: [Self.input(cost: 1)], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.configuration == latestConfiguration)
        #expect(controller.generation == 2)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(await forceRecorder.values == [.forceRefresh, .captureOnly])
        #expect(await gate.pendingCount == 0)
    }

    @Test
    func `disablement cancels pending work and clears safely`() async {
        let gate = SpendDashboardLoaderGate()
        let controller = Self.controller(gate: gate)
        controller.update(configuration: Self.configuration(account: "enabled"))
        await Self.waitForPendingCount(1, gate: gate)

        controller.update(configuration: SpendDashboardConfiguration(
            costUsageEnabled: false,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["enabled"]))
        #expect(!controller.isRefreshing)
        #expect(controller.model.groups.isEmpty)

        await gate.resume(at: 0, result: .init(inputs: [Self.input(cost: 99)], failedSourceIDs: []))
        await Task.yield()
        #expect(controller.model.groups.isEmpty)
    }

    @Test
    func `range selection persists only supported windows`() throws {
        let suite = "SpendDashboardControllerTests-days"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { mode in
                Self.request(
                    configuration: Self.configuration(account: "unused"),
                    force: mode.forcesLoader)
            })

        #expect(controller.selectedDays == 30)
        controller.selectDays(7)
        #expect(controller.selectedDays == 7)
        #expect(defaults.integer(forKey: "settingsSpendDashboardDays") == 7)
        controller.selectDays(9)
        #expect(controller.selectedDays == 30)
    }

    private static func controller(gate: SpendDashboardLoaderGate) -> SpendDashboardController {
        let controllerBox = SpendDashboardControllerBox()
        let captureStore = SpendDashboardCapturedInputStore()
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                let configuration = controllerBox.controller?.configuration
                    ?? Self.configuration(account: "pending")
                return await SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: mode == .captureOnly ? captureStore.inputs : [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            loader: { request in
                let result = await gate.load(request)
                await captureStore.replace(with: result.inputs)
                return result
            })
        controllerBox.controller = controller
        return controller
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

    private static func configuration(
        account: String,
        revision: String = "",
        sourceOwnershipFingerprint: String = "") -> SpendDashboardConfiguration
    {
        SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [account],
            sourceOwnershipFingerprints: [sourceOwnershipFingerprint],
            sourceRevisions: [revision])
    }

    private static func input(
        id: String? = nil,
        provider: UsageProvider = .codex,
        cost: Double) -> SpendDashboardModel.ProviderInput
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
            displayName: provider.rawValue,
            snapshot: snapshot)
    }

    private static func waitForPendingCount(_ count: Int, gate: SpendDashboardLoaderGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) pending loads")
    }

    private static func waitForCodexPendingCount(_ count: Int, gate: SpendDashboardCodexSnapshotGate) async {
        for _ in 0..<1000 {
            if await gate.pendingCount == count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) pending Codex loads")
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

@MainActor
struct SpendDashboardRequestTimeTests {
    @Test
    func `default request time resolves after provider refresh boundary`() async throws {
        let (settings, store) = Self.store(suiteName: "SpendDashboardRequestTimeTests-capture")
        let refreshFinished = LockIsolated(false)
        store._test_tokenUsageRefreshOverride = { _, _ in
            refreshFinished.setValue(true)
        }
        let afterMidnight = try #require(ISO8601DateFormatter().date(from: "2026-07-17T00:00:01Z"))

        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .forceRefresh,
            nowProvider: {
                #expect(refreshFinished.value)
                return afterMidnight
            })

        #expect(request.now == afterMidnight)
    }

    @Test
    func `explicit request time remains authoritative after refresh`() async throws {
        let (settings, store) = Self.store(suiteName: "SpendDashboardRequestTimeTests-explicit")
        store._test_tokenUsageRefreshOverride = { _, _ in }
        let injected = try #require(ISO8601DateFormatter().date(from: "2026-07-16T23:59:59Z"))

        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .forceRefresh,
            now: injected,
            nowProvider: {
                Issue.record("Explicit request time must not read the default clock")
                return Date.distantFuture
            })

        #expect(request.now == injected)
    }

    private static func store(suiteName: String) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }
}

@MainActor
struct SpendDashboardControllerRevisionTests {
    private struct CompletenessReloadCase {
        let name: String
        let snapshot: CostUsageTokenSnapshot
        let expectedTokens: Int?
        let expectedCost: Double?
        let expectedCompleteness: SpendDashboardModel.ModelHistoryCompleteness
    }

    @Test
    func `snapshot revision includes every dashboard completeness metric`() {
        let baseline = Self.completenessSnapshot()
        let baselineRevision = Self.sourceRevision(
            snapshot: baseline,
            suiteName: "SpendDashboardControllerTests-completeness-revision-baseline")
        let mutations: [(String, CostUsageTokenSnapshot)] = [
            ("history coverage", Self.completenessSnapshot(historyCoverageIsEstablished: false)),
            ("last 30 day tokens", Self.completenessSnapshot(last30DaysTokens: 1)),
            ("last 30 day cost", Self.completenessSnapshot(last30DaysCostUSD: 1)),
            ("entry input tokens", Self.completenessSnapshot(entryInputTokens: 1)),
            ("entry cache read tokens", Self.completenessSnapshot(entryCacheReadTokens: 1)),
            ("entry cache creation tokens", Self.completenessSnapshot(entryCacheCreationTokens: 1)),
            ("entry output tokens", Self.completenessSnapshot(entryOutputTokens: 1)),
            ("entry request count", Self.completenessSnapshot(entryRequestCount: 1)),
            ("breakdown request count", Self.completenessSnapshot(breakdownRequestCount: 1)),
            ("breakdown standard cost", Self.completenessSnapshot(breakdownStandardCostUSD: 1)),
            ("breakdown priority cost", Self.completenessSnapshot(breakdownPriorityCostUSD: 1)),
            ("breakdown standard tokens", Self.completenessSnapshot(breakdownStandardTokens: 1)),
            ("breakdown priority tokens", Self.completenessSnapshot(breakdownPriorityTokens: 1)),
        ]

        for (index, mutation) in mutations.enumerated() {
            let revision = Self.sourceRevision(
                snapshot: mutation.1,
                suiteName: "SpendDashboardControllerTests-completeness-revision-\(index)")
            #expect(revision != baselineRevision, "\(mutation.0) must affect the snapshot revision")
        }
    }

    @Test
    func `same timestamp completeness mutations reload with metric specific validity`() async {
        let mutations: [CompletenessReloadCase] = [
            .init(
                name: "last 30 day aggregates",
                snapshot: Self.completenessSnapshot(
                    date: "malformed",
                    last30DaysTokens: 1,
                    last30DaysCostUSD: 1),
                expectedTokens: nil,
                expectedCost: nil,
                expectedCompleteness: .incomplete),
            .init(
                name: "entry request count",
                snapshot: Self.completenessSnapshot(date: "malformed", entryRequestCount: 1),
                expectedTokens: 0,
                expectedCost: 0,
                expectedCompleteness: .complete),
            .init(
                name: "breakdown standard cost",
                snapshot: Self.completenessSnapshot(date: "malformed", breakdownStandardCostUSD: 1),
                expectedTokens: 0,
                expectedCost: nil,
                expectedCompleteness: .incomplete),
        ]

        for (index, mutation) in mutations.enumerated() {
            let baseline = Self.completenessSnapshot(date: "malformed")
            let (settings, store) = Self.revisionStore(
                suiteName: "SpendDashboardControllerTests-completeness-reload-\(index)")
            let baselineConfiguration = Self.configuration(snapshot: baseline, settings: settings, store: store)
            let replacementConfiguration = Self.configuration(
                snapshot: mutation.snapshot,
                settings: settings,
                store: store)
            let gate = SpendDashboardLoaderGate()
            let controller = Self.controller(gate: gate)

            #expect(
                baselineConfiguration.sourceRevisions != replacementConfiguration.sourceRevisions,
                "\(mutation.name) must invalidate the dashboard request")

            controller.update(configuration: baselineConfiguration)
            await Self.waitForPendingCount(1, gate: gate)
            await gate.resume(at: 0, result: .init(
                inputs: [Self.input(provider: .claude, snapshot: baseline)],
                failedSourceIDs: []))
            await Self.waitUntil { !controller.isRefreshing }
            #expect(controller.model.groups.first?.providers.first?.totalTokens == 0)
            #expect(controller.model.groups.first?.modelHistoryCompleteness == .complete)

            controller.update(configuration: replacementConfiguration)
            await Self.waitForPendingCount(1, gate: gate)
            await gate.resume(at: 0, result: .init(
                inputs: [Self.input(provider: .claude, snapshot: mutation.snapshot)],
                failedSourceIDs: []))
            await Self.waitUntil { !controller.isRefreshing }

            #expect(controller.generation == 2, "\(mutation.name) must trigger a replacement load")
            #expect(controller.model.groups.first?.providers.first?.totalTokens == mutation.expectedTokens)
            #expect(controller.model.groups.first?.providers.first?.totalCost == mutation.expectedCost)
            #expect(
                controller.model.groups.first?.modelHistoryCompleteness == mutation.expectedCompleteness)
            #expect(controller.model.groups.first?.dailyPoints.isEmpty == true)
        }
    }

    private static func controller(gate: SpendDashboardLoaderGate) -> SpendDashboardController {
        let controllerBox = SpendDashboardControllerBox()
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                let configuration = controllerBox.controller?.configuration
                    ?? SpendDashboardConfiguration(
                        costUsageEnabled: false,
                        providerIDs: [],
                        codexAccountIdentities: [])
                return SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_784_179_200),
                    force: mode.forcesLoader)
            },
            loader: { request in await gate.load(request) })
        controllerBox.controller = controller
        return controller
    }

    private static func revisionStore(suiteName: String) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }

    private static func configuration(
        snapshot: CostUsageTokenSnapshot,
        settings: SettingsStore,
        store: UsageStore) -> SpendDashboardConfiguration
    {
        store._setTokenSnapshotForTesting(snapshot, provider: .claude)
        return SpendDashboardSource.configuration(settings: settings, store: store)
    }

    private static func sourceRevision(
        snapshot: CostUsageTokenSnapshot,
        suiteName: String) -> [String]
    {
        let (settings, store) = Self.revisionStore(suiteName: suiteName)
        return Self.configuration(snapshot: snapshot, settings: settings, store: store).sourceRevisions
    }

    private static func completenessSnapshot(
        date: String = "2026-07-15",
        historyCoverageIsEstablished: Bool = true,
        last30DaysTokens: Int? = 0,
        last30DaysCostUSD: Double? = 0,
        entryInputTokens: Int? = nil,
        entryCacheReadTokens: Int? = nil,
        entryCacheCreationTokens: Int? = nil,
        entryOutputTokens: Int? = nil,
        entryRequestCount: Int? = nil,
        breakdownRequestCount: Int? = nil,
        breakdownStandardCostUSD: Double? = nil,
        breakdownPriorityCostUSD: Double? = nil,
        breakdownStandardTokens: Int? = nil,
        breakdownPriorityTokens: Int? = nil) -> CostUsageTokenSnapshot
    {
        let breakdown = CostUsageDailyReport.ModelBreakdown(
            modelName: "",
            costUSD: 0,
            totalTokens: 0,
            requestCount: breakdownRequestCount,
            standardCostUSD: breakdownStandardCostUSD,
            priorityCostUSD: breakdownPriorityCostUSD,
            standardTokens: breakdownStandardTokens,
            priorityTokens: breakdownPriorityTokens)
        let entry = CostUsageDailyReport.Entry(
            date: date,
            inputTokens: entryInputTokens,
            outputTokens: entryOutputTokens,
            cacheReadTokens: entryCacheReadTokens,
            cacheCreationTokens: entryCacheCreationTokens,
            totalTokens: 0,
            requestCount: entryRequestCount,
            costUSD: 0,
            modelsUsed: nil,
            modelBreakdowns: [breakdown])
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }

    private static func input(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            provider: provider,
            displayName: provider.rawValue,
            snapshot: snapshot)
    }

    private static func waitForPendingCount(_ count: Int, gate: SpendDashboardLoaderGate) async {
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

@MainActor
private final class SpendDashboardControllerBox {
    var controller: SpendDashboardController?
}

private actor SpendDashboardRefreshRecorder {
    private(set) var providers: [UsageProvider] = []

    func append(_ provider: UsageProvider) {
        self.providers.append(provider)
    }
}

private actor SpendDashboardForceRecorder {
    private(set) var values: [SpendDashboardRequestBuildMode] = []

    func append(_ mode: SpendDashboardRequestBuildMode) {
        self.values.append(mode)
    }
}

private actor SpendDashboardCapturedInputStore {
    private(set) var inputs: [SpendDashboardModel.ProviderInput] = []

    func replace(with inputs: [SpendDashboardModel.ProviderInput]) {
        self.inputs = inputs
    }
}

private actor SpendDashboardCodexLoadRecorder {
    private(set) var contexts: [CodexSpendSnapshotLoadContext] = []

    func record(_ context: CodexSpendSnapshotLoadContext) {
        self.contexts.append(context)
    }
}

private actor SpendDashboardLoadResultRecorder {
    private(set) var results: [SpendDashboardLoadResult] = []

    func record(_ result: SpendDashboardLoadResult) {
        self.results.append(result)
    }
}

private actor SpendDashboardCodexSnapshotGate {
    private var continuations: [CheckedContinuation<CostUsageTokenSnapshot, Never>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func load(_ context: CodexSpendSnapshotLoadContext) async -> CostUsageTokenSnapshot {
        _ = context
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func resume(at index: Int, snapshot: CostUsageTokenSnapshot) {
        self.continuations.remove(at: index).resume(returning: snapshot)
    }
}

private actor SpendDashboardLoaderGate {
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

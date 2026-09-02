import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardCodexProxySourceTests {
    @Test
    func `unrelated dashboard providers skip proxy attribution guard capture`() {
        #expect(!UsageStore.spendDashboardTokenUsageNeedsCLIProxyAPIAttributionGuard(.cursor))
        #expect(!UsageStore.spendDashboardTokenUsageNeedsCLIProxyAPIAttributionGuard(.gemini))
        #expect(UsageStore.spendDashboardTokenUsageNeedsCLIProxyAPIAttributionGuard(.claude))
        #expect(UsageStore.spendDashboardTokenUsageNeedsCLIProxyAPIAttributionGuard(.codex))
    }

    @Test
    func `proxy usage loads once beside account scoped codex snapshots`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let accounts = ["first", "second"].map { id in
            CodexSpendScanRequest(
                id: id,
                displayName: "Codex · \(id)",
                source: .profileHome(path: "/synthetic/\(id)"),
                homePath: "/synthetic/\(id)",
                authFingerprint: nil,
                authFileWasReadable: false,
                cacheIdentity: "\(id)-cache")
        }
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: accounts.map { "\($0.id)|\($0.cacheIdentity)" }),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: accounts,
            now: now,
            force: false)
        let proxyRecorder = SpendDashboardCodexProxyLoadRecorder()
        let accountSnapshot = Self.snapshot(cost: 1, now: now)
        let proxySnapshot = Self.snapshot(cost: 2, now: now)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in accountSnapshot },
            codexProxySnapshotLoader: { context in
                await proxyRecorder.record(context)
                return proxySnapshot
            })
        let proxyContexts = await proxyRecorder.contexts

        #expect(Set(result.inputs.map(\.id)) == [
            "codex:first",
            "codex:second",
            SpendDashboardSource.codexProxySourceID,
        ])
        #expect(result.inputs.count { $0.id == SpendDashboardSource.codexProxySourceID } == 1)
        #expect(result.inputs.first { $0.id == SpendDashboardSource.codexProxySourceID }?.displayName ==
            "Codex · CLIProxyAPI")
        #expect(result.inputs.first { $0.id == SpendDashboardSource.codexProxySourceID }?.sourceKind == .cliProxyAPI)
        #expect(proxyContexts.count == 1)
        #expect(proxyContexts.first?.now == now)
    }

    @Test
    func `proxy usage loads when claude is enabled without codex`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.claude.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: now,
            force: false)
        let proxySnapshot = Self.snapshot(cost: 2, now: now)
        let emptySnapshot = Self.snapshot(cost: 0, now: now)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in
                Issue.record("No account-scoped Codex snapshot should be requested.")
                return emptySnapshot
            },
            codexProxySnapshotLoader: { _ in proxySnapshot })

        #expect(result.inputs.map(\.id) == [SpendDashboardSource.codexProxySourceID])
    }

    @Test
    func `proxy usage supplements claude overview without adding a subscription`() async throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            codexAccountIdentities: [])
        let request = SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: now,
            force: false)
        let proxyInput = SpendDashboardModel.ProviderInput(
            id: SpendDashboardSource.codexProxySourceID,
            provider: .codex,
            displayName: "Codex · CLIProxyAPI",
            snapshot: Self.snapshot(cost: 2, now: now),
            sourceKind: .cliProxyAPI)
        let controller = SpendDashboardController(
            requestBuilder: { _ in request },
            loader: { _ in SpendDashboardLoadResult(inputs: [proxyInput], failedSourceIDs: []) })

        controller.update(configuration: configuration)
        let deadline = Date().addingTimeInterval(2)
        while controller.isRefreshing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }

        let publication = controller.publication
        let proxySource = try #require(publication.sources.first {
            $0.id == SpendDashboardSource.codexProxySourceID
        })
        let claudeOnly = publication.model(
            requestedDays: 7,
            now: now,
            calendar: .current,
            preferredCurrencyCode: "USD",
            providerScope: [.claude])
        let combined = publication.model(
            requestedDays: 7,
            now: now,
            calendar: .current,
            preferredCurrencyCode: "USD",
            providerScope: [.claude, .codex])

        #expect(!controller.isRefreshing)
        #expect(proxySource.role == .supplemental)
        #expect(claudeOnly.groups.flatMap(\.providers).map(\.id) == [SpendDashboardSource.codexProxySourceID])
        #expect(combined.groups.flatMap(\.providers).count { $0.id == SpendDashboardSource.codexProxySourceID } == 1)
        #expect(publication.subscriptionCount(providerScope: [.claude]) == 1)
    }

    @Test
    func `proxy usage stays visible when OpenCodex hides native Codex`() {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let inputs = [
            SpendDashboardModel.ProviderInput(
                id: "codex:main", provider: .codex, displayName: "Codex", snapshot: Self.snapshot(cost: 1, now: now)),
            SpendDashboardModel.ProviderInput(
                id: SpendDashboardModel.openCodexSourceID,
                provider: .codex,
                displayName: "OpenCodex",
                snapshot: Self.snapshot(cost: 2, now: now),
                sourceKind: .openCodex),
            SpendDashboardModel.ProviderInput(
                id: SpendDashboardSource.codexProxySourceID,
                provider: .codex,
                displayName: "Codex · CLIProxyAPI",
                snapshot: Self.snapshot(cost: 3, now: now),
                sourceKind: .cliProxyAPI),
        ]

        let model = SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: now,
            hideNativeCodexWhenOpenCodexPresent: true)

        #expect(Set(model.groups.flatMap(\.providers).map(\.id)) == [
            SpendDashboardModel.openCodexSourceID,
            SpendDashboardSource.codexProxySourceID,
        ])
    }

    @Test
    func `proxy usage is invalidated when attribution boundaries change during load`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let proxySnapshot = Self.snapshot(cost: 2, now: now)
        let staleProxyInput = SpendDashboardModel.ProviderInput(
            id: SpendDashboardSource.codexProxySourceID,
            provider: .codex,
            displayName: "Codex · CLIProxyAPI",
            modelProviderName: "Codex",
            snapshot: proxySnapshot)
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.claude.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [staleProxyInput],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: now,
            force: false)
        let initialGuard = CLIProxyAPIAttributionPublicationGuard(
            configurationGeneration: "generation-a",
            telemetryRevision: "telemetry-a",
            inputArtifactFingerprint: "artifact-a",
            isIsolated: false)
        let changedGuards = [
            CLIProxyAPIAttributionPublicationGuard(
                configurationGeneration: "generation-b",
                telemetryRevision: "telemetry-a",
                inputArtifactFingerprint: "artifact-a",
                isIsolated: false),
            CLIProxyAPIAttributionPublicationGuard(
                configurationGeneration: "generation-a",
                telemetryRevision: "telemetry-b",
                inputArtifactFingerprint: "artifact-a",
                isIsolated: false),
            CLIProxyAPIAttributionPublicationGuard(
                configurationGeneration: "generation-a",
                telemetryRevision: "telemetry-a",
                inputArtifactFingerprint: "artifact-b",
                isIsolated: false),
            CLIProxyAPIAttributionPublicationGuard(
                configurationGeneration: "generation-a",
                telemetryRevision: "telemetry-a",
                inputArtifactFingerprint: "artifact-a",
                isIsolated: true),
        ]

        for changedGuard in changedGuards {
            let guardLoadCount = LockIsolated(0)
            let result = await SpendDashboardSource.load(
                request,
                codexSnapshotLoader: { _ in
                    Issue.record("No account-scoped Codex snapshot should be requested.")
                    return proxySnapshot
                },
                codexProxySnapshotLoader: { _ in proxySnapshot },
                codexProxyAttributionGuardLoader: {
                    let loadCount = guardLoadCount.value
                    guardLoadCount.setValue(loadCount + 1)
                    return loadCount == 0 ? initialGuard : changedGuard
                })

            #expect(result.inputs.isEmpty)
            #expect(result.failedSourceIDs == [SpendDashboardSource.codexProxySourceID])
            #expect(result.invalidatedSourceIDs == [SpendDashboardSource.codexProxySourceID])
            #expect(guardLoadCount.value == 2)
        }
    }

    @Test
    func `cancelled proxy load preserves direct account and invalidates retained proxy source`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let account = CodexSpendScanRequest(
            id: "first",
            displayName: "Codex · first",
            source: .profileHome(path: "/synthetic/first"),
            homePath: "/synthetic/first",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "first-cache")
        let staleProxyInput = SpendDashboardModel.ProviderInput(
            id: SpendDashboardSource.codexProxySourceID,
            provider: .codex,
            displayName: "Codex · CLIProxyAPI",
            modelProviderName: "Codex",
            snapshot: Self.snapshot(cost: 2, now: now))
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: ["\(account.id)|\(account.cacheIdentity)"]),
            capturedInputs: [staleProxyInput],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: now,
            force: false)
        let accountSnapshot = Self.snapshot(cost: 1, now: now)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in accountSnapshot },
            codexProxySnapshotLoader: { _ in throw CancellationError() })

        #expect(result.inputs.map(\.id) == ["codex:first"])
        #expect(result.failedSourceIDs == [SpendDashboardSource.codexProxySourceID])
        #expect(result.invalidatedSourceIDs == [SpendDashboardSource.codexProxySourceID])
    }

    private static func snapshot(cost: Double, now: Date) -> CostUsageTokenSnapshot {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: cost,
            modelsUsed: ["gpt-5.5"],
            modelBreakdowns: nil)
        return CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [entry],
            updatedAt: now)
    }
}

private actor SpendDashboardCodexProxyLoadRecorder {
    private(set) var contexts: [CodexProxySpendSnapshotLoadContext] = []

    func record(_ context: CodexProxySpendSnapshotLoadContext) {
        self.contexts.append(context)
    }
}

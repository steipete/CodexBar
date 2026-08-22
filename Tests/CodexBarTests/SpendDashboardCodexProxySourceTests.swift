import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardCodexProxySourceTests {
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

import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CLIProxyAPIPublicationGuardTests {
    @Test
    func `live refresh guard rejects cross process proxy state changes`() async throws {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIPublicationGuardTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-live-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proxyHome = root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        var scannerOptions = CostUsageScanner.Options()
        scannerOptions.cacheRoot = root
        scannerOptions.cliProxyAPIHome = proxyHome
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: scannerOptions),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let historyDays = settings.costUsageHistoryDays
        let scopeSignature = store.tokenSnapshotScopeSignature(for: .codex)

        #expect(await store.tokenRefreshPublicationGuard(for: .claude).cliProxyAPIAttribution != nil)
        #expect(await store.tokenRefreshPublicationGuard(for: .codex).cliProxyAPIAttribution != nil)
        #expect(await store.tokenRefreshPublicationGuard(for: .cursor).cliProxyAPIAttribution == nil)
        #expect(await store.tokenRefreshPublicationGuard(for: .gemini).cliProxyAPIAttribution == nil)

        let generationGuard = await store.tokenRefreshPublicationGuard(for: .codex)
        let artifactDirectory = root.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: artifactDirectory.appendingPathComponent("codex-v11.json"))
        let clearResult = CostUsageCacheLocations.clearAllCostUsageCaches(
            in: [artifactDirectory],
            stateRoot: root)
        #expect(clearResult.errorDescription == nil)
        let generationIsCurrent = await store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: generationGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature)
        #expect(!generationIsCurrent)

        let telemetryGuard = await store.tokenRefreshPublicationGuard(for: .codex)
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: now,
                    provider: "codex",
                    model: "gpt-5.4",
                    alias: "gpt-5.4",
                    endpoint: "POST /v1/messages",
                    authType: "oauth",
                    requestID: "live-publication-race",
                    tokens: .init(input: 10, output: 20, total: 30)),
            ],
            cacheRoot: root,
            now: now) == 1)
        let telemetryIsCurrent = await store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: telemetryGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature)
        #expect(!telemetryIsCurrent)

        let artifactGuard = await store.tokenRefreshPublicationGuard(for: .codex)
        let logDirectory = proxyHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try Data("request".utf8).write(to: logDirectory.appendingPathComponent("request.log"))
        let artifactIsCurrent = await store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: artifactGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature)
        #expect(!artifactIsCurrent)

        let isolationGuard = await store.tokenRefreshPublicationGuard(for: .codex)
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(true, stateRoot: root))
        let isolationIsCurrent = await store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: isolationGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature)
        #expect(!isolationIsCurrent)
    }
}

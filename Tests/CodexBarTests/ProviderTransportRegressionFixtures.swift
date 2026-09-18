import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderTransportRegressionFixtures: TestTrait, SuiteTrait, TestScoping {
    @TaskLocal private static var currentRoot: URL?

    static var root: URL {
        guard let currentRoot else { preconditionFailure("Add ProviderTransportRegressionFixtures") }
        return currentRoot
    }

    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void) async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.$currentRoot.withValue(root) {
            try await KeychainCacheStore.withServiceOverrideForTesting("transport-\(UUID().uuidString)") {
                try await KeychainCacheStore.withImplicitTestStoreForTesting {
                    try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(
                        root.appendingPathComponent("legacy"))
                    {
                        try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
                            try await Self.withPrivateClaudeState(root: root, operation: function)
                        }
                    }
                }
            }
        }
    }

    private static func withPrivateClaudeState(
        root: URL,
        operation: @Sendable () async throws -> Void) async throws
    {
        try await UsageStore.withActiveClaudeAccountUuidForTesting(nil) {
            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                root.appendingPathComponent("missing-claude-credentials.json"))
            {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            try await operation()
                        }
                    }
                }
            }
        }
    }
}

enum ProviderTransportRegressionSupport {
    static let codes: [URLError.Code] = [
        .timedOut, .cancelled, .networkConnectionLost, .notConnectedToInternet,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]
    static let capturedAt = Date(timeIntervalSince1970: 1_789_473_600)

    static func urlError(_ code: URLError.Code = .cannotFindHost) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Verbindung fehlgeschlagen",
            "fixture-marker": "preserved",
        ])
    }

    static func browser(root: URL) -> BrowserDetection {
        BrowserDetection(
            homeDirectory: root.path,
            cacheTTL: 0,
            now: { Self.capturedAt },
            fileExists: { _ in false },
            directoryContents: { _ in nil },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
    }

    static var environment: [String: String] {
        let root = ProviderTransportRegressionFixtures.root
        return [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent("codex").path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "CLOUDSDK_CONFIG": root.appendingPathComponent("gcloud").path,
            "GOOGLE_APPLICATION_CREDENTIALS": root.appendingPathComponent("missing-google.json").path,
            "OLLAMA_API_KEY": "fixture-ollama-key",
        ]
    }

    @MainActor
    static func captureFailure(_ operation: @MainActor () async throws -> Void) async -> Error {
        do {
            try await operation()
            Issue.record("Expected the injected provider failure")
            return NSError(domain: "missing-fixture-error", code: 1)
        } catch {
            return error
        }
    }

    @MainActor
    static func expectPolicy(_ error: Error, code: URLError.Code, description: String? = nil) {
        #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: false))
        #expect(UsageStore.isStartupConnectivityRetryableError(error) == (code != .cancelled))
        let hook = code == .cancelled ? "cancelled" : code == .timedOut ? "timeout" : "offline"
        #expect(UsageStore.refreshFailureHookStatus(error) == hook)
        if let description { #expect(error.localizedDescription == description) }
    }

    @MainActor
    static func withStore(
        provider: UsageProvider,
        hasPriorData: Bool = true,
        operation: @MainActor (UsageStore, UsageSnapshot) async throws -> Void) async throws
    {
        let root = ProviderTransportRegressionFixtures.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configStore = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        try configStore.save(testConfigWithAllProvidersDisabled())
        let settings = SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                fileURL: root.appendingPathComponent("antigravity.json")),
            keychainAccessPolicy: SettingsStoreKeychainAccessPolicy(
                setDisabled: { _ in }, isExplicitlyDisabled: { false }),
            performInitialProviderDetection: false)
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.claudeUsageDataSource = .oauth
        settings.ollamaUsageDataSource = .api
        settings.updateProviderConfig(provider: provider) { config in
            config.source = provider == .cursor ? .web : provider == .ollama ? .api : .oauth
        }
        enableTestProviders([provider], settings: settings)
        let environment = Self.environment
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: Self.browser(root: root),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: root
                .appendingPathComponent("history.json")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing,
            environmentBase: environment,
            pluginApprovalStore: ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("plugins.json")),
            widgetSnapshotURL: root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
        defer {
            store._test_providerFetchOutcomeOverride = nil
            store._test_widgetSnapshotSaveOverride = nil
            store.stopSharedSpendDashboardPublication()
            settings.configFileWatcher?.stop()
        }
        let hasQuota = provider == .claude || provider == .cursor
        let prior = UsageSnapshot(
            primary: hasQuota ? RateWindow(
                usedPercent: 17, windowMinutes: 300, resetsAt: nil, resetDescription: nil) : nil,
            secondary: hasQuota ? RateWindow(
                usedPercent: 31, windowMinutes: 10080, resetsAt: nil, resetDescription: nil) : nil,
            updatedAt: Self.capturedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: provider == .ollama ? nil : "fixture@example.test",
                accountOrganization: nil,
                loginMethod: provider == .ollama ? "API key" : "Pro"))
        if hasPriorData { store._setSnapshotForTesting(prior, provider: provider) }
        do {
            try await operation(store, prior)
        } catch {
            await store.widgetSnapshotPersistTask?.value
            throw error
        }
        await store.widgetSnapshotPersistTask?.value
    }
}

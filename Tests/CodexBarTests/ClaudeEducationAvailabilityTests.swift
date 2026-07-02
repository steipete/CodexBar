import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeEducationAvailabilityTests {
    @Test
    func `auto CLI subscription notice is terminal before web fallback`() {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let strategy = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            manualCookieHeader: "sessionKey=test-session",
            browserDetection: browserDetection,
            hasWebFallback: true)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)

        let unavailable = ClaudeStatusProbeError.parseFailed(
            ClaudeStatusProbe.subscriptionQuotaUnavailableDescription)
        #expect(!strategy.shouldFallback(on: unavailable, context: context))
        #expect(strategy.shouldFallback(on: ClaudeStatusProbeError.timedOut, context: context))
    }

    @Test
    func `subscription-only response is informational across Claude surfaces`() async throws {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let (store, tokenSnapshot) = try await MainActor.run {
                    let settings = testSettingsStore(suiteName: "ClaudeEducationAvailabilityTests")
                    settings.refreshFrequency = .manual
                    settings.statusChecksEnabled = false
                    settings.claudeUsageDataSource = .cli
                    settings.claudeOAuthKeychainPromptMode = .never
                    settings.providerDetectionCompleted = true

                    let metadata = ProviderRegistry.shared.metadata
                    for provider in UsageProvider.allCases {
                        try settings.setProviderEnabled(
                            provider: provider,
                            metadata: #require(metadata[provider]),
                            enabled: provider == .claude)
                    }

                    let store = UsageStore(
                        fetcher: UsageFetcher(environment: [:]),
                        browserDetection: BrowserDetection(cacheTTL: 0),
                        settings: settings,
                        startupBehavior: .testing,
                        environmentBase: [:])
                    store._setSnapshotForTesting(
                        UsageSnapshot(
                            primary: RateWindow(
                                usedPercent: 12,
                                windowMinutes: 300,
                                resetsAt: nil,
                                resetDescription: nil),
                            secondary: RateWindow(
                                usedPercent: 34,
                                windowMinutes: 10080,
                                resetsAt: nil,
                                resetDescription: nil),
                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            identity: ProviderIdentitySnapshot(
                                providerID: .claude,
                                accountEmail: "claude@example.com",
                                accountOrganization: nil,
                                loginMethod: "Education")),
                        provider: .claude)
                    let tokenSnapshot = CostUsageTokenSnapshot(
                        sessionTokens: 4200,
                        sessionCostUSD: 1.25,
                        last30DaysTokens: 42000,
                        last30DaysCostUSD: 12.50,
                        daily: [],
                        updatedAt: Date(timeIntervalSince1970: 1_800_000_001))
                    store._setTokenSnapshotForTesting(tokenSnapshot, provider: .claude)
                    try Self.installStrategy(ClaudeSubscriptionOnlyFetchStrategy(), in: store)
                    return (store, tokenSnapshot)
                }

                await store.refreshProvider(.claude)
                await MainActor.run {
                    let pane = ProvidersPane(settings: store.settings, store: store)
                    let menuModel = pane._test_menuCardModel(for: .claude)
                    let descriptor = MenuDescriptor.build(
                        provider: .claude,
                        store: store,
                        settings: store.settings,
                        account: AccountInfo(email: nil, plan: nil),
                        updateReady: false,
                        includeContextualActions: false)
                    let descriptorLines = descriptor.sections
                        .flatMap(\.entries)
                        .compactMap { entry -> String? in
                            guard case let .text(text, _) = entry else { return nil }
                            return text
                        }

                    #expect(store.snapshot(for: .claude) == nil)
                    #expect(store.error(for: .claude) == nil)
                    #expect(store.knownLimitsAvailability(for: .claude) == .unavailable)
                    #expect(!store.isStale(provider: .claude))
                    #expect(store.hasSatisfiedUsageFetch(for: .claude))
                    #expect(!store.needsUsageRefreshRetry(for: .claude))
                    #expect(store.tokenSnapshot(for: .claude) == tokenSnapshot)
                    #expect(pane._test_providerErrorDisplay(for: .claude) == nil)
                    #expect(pane._test_providerSidebarSubtitle(.claude).hasSuffix("\nLimits not available"))
                    #expect(menuModel.placeholder == "Limits not available")
                    #expect(descriptorLines.contains("Limits not available"))
                    #expect(!descriptorLines.contains("No usage yet"))
                }

                try await MainActor.run {
                    try Self.installStrategy(ClaudeAvailabilityTimeoutFetchStrategy(), in: store)
                }
                await store.refreshProvider(.claude)

                await MainActor.run {
                    #expect(store.error(for: .claude) == nil)
                    #expect(store.knownLimitsAvailability(for: .claude) == .unavailable)
                    #expect(!store.isStale(provider: .claude))
                    #expect(store.hasSatisfiedUsageFetch(for: .claude))
                    #expect(!store.needsUsageRefreshRetry(for: .claude))
                    #expect(store.tokenSnapshot(for: .claude) == tokenSnapshot)
                }
            }
        }
    }

    @MainActor
    private static func installStrategy(
        _ strategy: some ProviderFetchStrategy,
        in store: UsageStore) throws
    {
        let currentSpec = try #require(store.providerSpecs[.claude])
        let currentDescriptor = currentSpec.descriptor
        store.providerSpecs[.claude] = ProviderSpec(
            style: currentSpec.style,
            isEnabled: currentSpec.isEnabled,
            descriptor: ProviderDescriptor(
                id: .claude,
                metadata: currentDescriptor.metadata,
                branding: currentDescriptor.branding,
                tokenCost: currentDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.cli],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: currentDescriptor.cli),
            makeFetchContext: currentSpec.makeFetchContext)
    }
}

private struct ClaudeAvailabilityTimeoutFetchStrategy: ProviderFetchStrategy {
    let id = "test.claude-availability-timeout"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw ClaudeStatusProbeError.timedOut
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct ClaudeSubscriptionOnlyFetchStrategy: ProviderFetchStrategy {
    let id = "test.claude-subscription-only"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw ClaudeStatusProbeError.parseFailed(ClaudeStatusProbe.subscriptionQuotaUnavailableDescription)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

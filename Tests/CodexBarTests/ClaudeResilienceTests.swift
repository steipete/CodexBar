import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeResilienceTests {
    @Test
    func `cancelled Claude refresh never publishes an error`() async throws {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let store = try await MainActor.run {
                    let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-cancellation")
                    settings.refreshFrequency = .manual
                    settings.statusChecksEnabled = false
                    settings.claudeUsageDataSource = .cli
                    settings.claudeOAuthKeychainPromptMode = .never

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
                    let baseSpec = try #require(store.providerSpecs[.claude])
                    let descriptor = ProviderDescriptor(
                        id: .claude,
                        metadata: baseSpec.descriptor.metadata,
                        branding: baseSpec.descriptor.branding,
                        tokenCost: baseSpec.descriptor.tokenCost,
                        fetchPlan: ProviderFetchPlan(
                            sourceModes: [.cli],
                            pipeline: ProviderFetchPipeline { _ in [CancellationFetchStrategy()] }),
                        cli: baseSpec.descriptor.cli)
                    store.providerSpecs[.claude] = ProviderSpec(
                        style: baseSpec.style,
                        isEnabled: baseSpec.isEnabled,
                        descriptor: descriptor,
                        makeFetchContext: baseSpec.makeFetchContext)
                    return store
                }

                await store.refreshProvider(.claude)
                let result = await MainActor.run {
                    (
                        hasSnapshot: store.snapshot(for: .claude) != nil,
                        error: store.error(for: .claude))
                }

                #expect(!result.hasSnapshot)
                #expect(result.error == nil)
            }
        }
    }

    @Test
    func `superseded credential change clears prior Claude state after cancellation`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try Data("{}".utf8).write(to: fileURL)

                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())
                    let cancellations = CredentialSwapCancellationSequence(credentialsFileURL: fileURL)

                    let store = try await MainActor.run {
                        let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-cancelled-auth-change")
                        settings.refreshFrequency = .manual
                        settings.statusChecksEnabled = false
                        settings.claudeUsageDataSource = .cli
                        settings.claudeOAuthKeychainPromptMode = .never

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
                                secondary: nil,
                                updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                identity: ProviderIdentitySnapshot(
                                    providerID: .claude,
                                    accountEmail: "old@example.com",
                                    accountOrganization: nil,
                                    loginMethod: "Pro")),
                            provider: .claude)
                        store._setTokenSnapshotForTesting(
                            CostUsageTokenSnapshot(
                                sessionTokens: 4200,
                                sessionCostUSD: 1.25,
                                last30DaysTokens: 42000,
                                last30DaysCostUSD: 12.50,
                                daily: [],
                                updatedAt: Date(timeIntervalSince1970: 1_800_000_001)),
                            provider: .claude)

                        let baseSpec = try #require(store.providerSpecs[.claude])
                        let descriptor = ProviderDescriptor(
                            id: .claude,
                            metadata: baseSpec.descriptor.metadata,
                            branding: baseSpec.descriptor.branding,
                            tokenCost: baseSpec.descriptor.tokenCost,
                            fetchPlan: ProviderFetchPlan(
                                sourceModes: [.cli],
                                pipeline: ProviderFetchPipeline { _ in
                                    [CancellationAfterCredentialSwapFetchStrategy(cancellations: cancellations)]
                                }),
                            cli: baseSpec.descriptor.cli)
                        store.providerSpecs[.claude] = ProviderSpec(
                            style: baseSpec.style,
                            isEnabled: baseSpec.isEnabled,
                            descriptor: descriptor,
                            makeFetchContext: baseSpec.makeFetchContext)
                        return store
                    }

                    let olderRefresh = Task {
                        await store.refreshProvider(.claude)
                    }
                    await cancellations.waitUntilStarted(count: 1)
                    let newerRefresh = Task {
                        await store.refreshProvider(.claude)
                    }
                    await newerRefresh.value
                    await olderRefresh.value
                    let result = await MainActor.run {
                        (
                            hasSnapshot: store.snapshot(for: .claude) != nil,
                            hasTokenSnapshot: store.tokenSnapshot(for: .claude) != nil,
                            error: store.error(for: .claude))
                    }

                    #expect(!result.hasSnapshot)
                    #expect(!result.hasTokenSnapshot)
                    #expect(result.error == nil)
                }
            }
        }
    }

    @Test
    func `suppresses single flake when prior data exists`() {
        var gate = ConsecutiveFailureGate()
        let firstFailure = gate.shouldSurfaceError(onFailureWithPriorData: true)
        let secondFailure = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(firstFailure == false)
        #expect(secondFailure == true)
    }

    @Test
    func `surfaces failure without prior data`() {
        var gate = ConsecutiveFailureGate()
        let shouldSurface = gate.shouldSurfaceError(onFailureWithPriorData: false)
        #expect(shouldSurface)
    }

    @Test
    func `resets after success`() {
        var gate = ConsecutiveFailureGate()
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        gate.recordSuccess()
        let shouldSurface = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(shouldSurface == false)
    }

    @Test
    func `timeout keeps prior Claude snapshot without surfacing repeated failure`() async throws {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let (store, prior) = try await MainActor.run {
                    let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-timeout-cache")
                    settings.refreshFrequency = .manual
                    settings.statusChecksEnabled = false
                    settings.claudeUsageDataSource = .cli

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
                    let prior = UsageSnapshot(
                        primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
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
                            loginMethod: "Pro"))
                    store._setSnapshotForTesting(prior, provider: .claude)

                    let baseSpec = try #require(store.providerSpecs[.claude])
                    let descriptor = ProviderDescriptor(
                        id: .claude,
                        metadata: baseSpec.descriptor.metadata,
                        branding: baseSpec.descriptor.branding,
                        tokenCost: baseSpec.descriptor.tokenCost,
                        fetchPlan: ProviderFetchPlan(
                            sourceModes: [.cli],
                            pipeline: ProviderFetchPipeline { _ in [TimeoutFetchStrategy()] }),
                        cli: baseSpec.descriptor.cli)
                    store.providerSpecs[.claude] = ProviderSpec(
                        style: baseSpec.style,
                        isEnabled: baseSpec.isEnabled,
                        descriptor: descriptor,
                        makeFetchContext: baseSpec.makeFetchContext)
                    return (store, prior)
                }

                await store.refreshProvider(.claude)
                let firstResult = await MainActor.run {
                    (
                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                        hasError: store.error(for: .claude) != nil)
                }

                #expect(firstResult.updatedAt == prior.updatedAt)
                #expect(!firstResult.hasError)

                await store.refreshProvider(.claude)
                let secondResult = await MainActor.run {
                    (
                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                        hasError: store.error(for: .claude) != nil)
                }

                #expect(secondResult.updatedAt == prior.updatedAt)
                #expect(!secondResult.hasError)
            }
        }
    }

    @Test
    func `repeated non probe transient failure still surfaces`() async throws {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let (store, prior) = try await MainActor.run {
                    let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-network-cache")
                    settings.refreshFrequency = .manual
                    settings.statusChecksEnabled = false
                    settings.claudeUsageDataSource = .cli

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
                    let prior = UsageSnapshot(
                        primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                        secondary: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        identity: ProviderIdentitySnapshot(
                            providerID: .claude,
                            accountEmail: "claude@example.com",
                            accountOrganization: nil,
                            loginMethod: "Pro"))
                    store._setSnapshotForTesting(prior, provider: .claude)

                    let baseSpec = try #require(store.providerSpecs[.claude])
                    let descriptor = ProviderDescriptor(
                        id: .claude,
                        metadata: baseSpec.descriptor.metadata,
                        branding: baseSpec.descriptor.branding,
                        tokenCost: baseSpec.descriptor.tokenCost,
                        fetchPlan: ProviderFetchPlan(
                            sourceModes: [.cli],
                            pipeline: ProviderFetchPipeline { _ in [NetworkLostFetchStrategy()] }),
                        cli: baseSpec.descriptor.cli)
                    store.providerSpecs[.claude] = ProviderSpec(
                        style: baseSpec.style,
                        isEnabled: baseSpec.isEnabled,
                        descriptor: descriptor,
                        makeFetchContext: baseSpec.makeFetchContext)
                    return (store, prior)
                }

                await store.refreshProvider(.claude)
                let firstResult = await MainActor.run {
                    (
                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                        hasError: store.error(for: .claude) != nil)
                }

                #expect(firstResult.updatedAt == prior.updatedAt)
                #expect(!firstResult.hasError)

                await store.refreshProvider(.claude)
                let secondResult = await MainActor.run {
                    (
                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                        hasError: store.error(for: .claude) != nil)
                }

                #expect(secondResult.updatedAt == prior.updatedAt)
                #expect(secondResult.hasError)
            }
        }
    }

    @Test
    func `credentials change clears prior Claude snapshot for non transient failure`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try Data("{}".utf8).write(to: fileURL)

                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())

                    let store = try await MainActor.run {
                        let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-auth-change")
                        settings.refreshFrequency = .manual
                        settings.statusChecksEnabled = false
                        settings.claudeUsageDataSource = .cli

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
                        let prior = UsageSnapshot(
                            primary: RateWindow(
                                usedPercent: 12,
                                windowMinutes: 300,
                                resetsAt: nil,
                                resetDescription: nil),
                            secondary: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            identity: ProviderIdentitySnapshot(
                                providerID: .claude,
                                accountEmail: "old@example.com",
                                accountOrganization: nil,
                                loginMethod: "Pro"))
                        store._setSnapshotForTesting(prior, provider: .claude)

                        let baseSpec = try #require(store.providerSpecs[.claude])
                        let descriptor = ProviderDescriptor(
                            id: .claude,
                            metadata: baseSpec.descriptor.metadata,
                            branding: baseSpec.descriptor.branding,
                            tokenCost: baseSpec.descriptor.tokenCost,
                            fetchPlan: ProviderFetchPlan(
                                sourceModes: [.cli],
                                pipeline: ProviderFetchPipeline { _ in
                                    [AuthFailureFetchStrategy(credentialsFileURL: fileURL)]
                                }),
                            cli: baseSpec.descriptor.cli)
                        store.providerSpecs[.claude] = ProviderSpec(
                            style: baseSpec.style,
                            isEnabled: baseSpec.isEnabled,
                            descriptor: descriptor,
                            makeFetchContext: baseSpec.makeFetchContext)
                        return store
                    }

                    await store.refreshProvider(.claude)
                    let result = await MainActor.run {
                        (
                            hasSnapshot: store.snapshot(for: .claude) != nil,
                            hasError: store.error(for: .claude) != nil)
                    }

                    #expect(!result.hasSnapshot)
                    #expect(result.hasError)
                }
            }
        }
    }

    @Test
    func `credentials change clears prior Claude snapshot for transient failure`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try Data("{}".utf8).write(to: fileURL)

                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())

                    let store = try await MainActor.run {
                        let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-transient-auth-change")
                        settings.refreshFrequency = .manual
                        settings.statusChecksEnabled = false
                        settings.claudeUsageDataSource = .cli

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
                        let prior = UsageSnapshot(
                            primary: RateWindow(
                                usedPercent: 12,
                                windowMinutes: 300,
                                resetsAt: nil,
                                resetDescription: nil),
                            secondary: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            identity: ProviderIdentitySnapshot(
                                providerID: .claude,
                                accountEmail: "old@example.com",
                                accountOrganization: nil,
                                loginMethod: "Pro"))
                        store._setSnapshotForTesting(prior, provider: .claude)

                        let baseSpec = try #require(store.providerSpecs[.claude])
                        let descriptor = ProviderDescriptor(
                            id: .claude,
                            metadata: baseSpec.descriptor.metadata,
                            branding: baseSpec.descriptor.branding,
                            tokenCost: baseSpec.descriptor.tokenCost,
                            fetchPlan: ProviderFetchPlan(
                                sourceModes: [.cli],
                                pipeline: ProviderFetchPipeline { _ in
                                    [TransientFailureAfterCredentialSwapFetchStrategy(credentialsFileURL: fileURL)]
                                }),
                            cli: baseSpec.descriptor.cli)
                        store.providerSpecs[.claude] = ProviderSpec(
                            style: baseSpec.style,
                            isEnabled: baseSpec.isEnabled,
                            descriptor: descriptor,
                            makeFetchContext: baseSpec.makeFetchContext)
                        return store
                    }

                    await store.refreshProvider(.claude)
                    let result = await MainActor.run {
                        (
                            hasSnapshot: store.snapshot(for: .claude) != nil,
                            hasError: store.error(for: .claude) != nil)
                    }

                    #expect(!result.hasSnapshot)
                    #expect(result.hasError)
                }
            }
        }
    }

    @Test
    func `keychain change clears prior Claude snapshot for transient failure`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            let storedFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "old")
            let currentFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 1,
                persistentRefHash: "new")
            let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore(
                fingerprint: storedFingerprint)

            try await ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(
                fingerprintStore)
            {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                        try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                            try await ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(true) {
                                try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: currentFingerprint)
                                {
                                    try await ClaudeOAuthCredentialsStore
                                        .withIsolatedCredentialsFileTrackingForTesting {
                                            let tempDir = FileManager.default.temporaryDirectory
                                                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                                            try FileManager.default.createDirectory(
                                                at: tempDir,
                                                withIntermediateDirectories: true)
                                            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

                                            try await ClaudeOAuthCredentialsStore
                                                .withCredentialsURLOverrideForTesting(fileURL) {
                                                    let store = try await MainActor.run {
                                                        let settings = Self.makeSettingsStore(
                                                            suite: "ClaudeResilienceTests-keychain-auth-change")
                                                        settings.refreshFrequency = .manual
                                                        settings.statusChecksEnabled = false
                                                        settings.claudeUsageDataSource = .cli

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
                                                        let prior = UsageSnapshot(
                                                            primary: RateWindow(
                                                                usedPercent: 12,
                                                                windowMinutes: 300,
                                                                resetsAt: nil,
                                                                resetDescription: nil),
                                                            secondary: nil,
                                                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                            identity: ProviderIdentitySnapshot(
                                                                providerID: .claude,
                                                                accountEmail: "old@example.com",
                                                                accountOrganization: nil,
                                                                loginMethod: "Pro"))
                                                        store._setSnapshotForTesting(prior, provider: .claude)

                                                        let baseSpec = try #require(store.providerSpecs[.claude])
                                                        let descriptor = ProviderDescriptor(
                                                            id: .claude,
                                                            metadata: baseSpec.descriptor.metadata,
                                                            branding: baseSpec.descriptor.branding,
                                                            tokenCost: baseSpec.descriptor.tokenCost,
                                                            fetchPlan: ProviderFetchPlan(
                                                                sourceModes: [.cli],
                                                                pipeline: ProviderFetchPipeline { _ in
                                                                    [TimeoutFetchStrategy()]
                                                                }),
                                                            cli: baseSpec.descriptor.cli)
                                                        store.providerSpecs[.claude] = ProviderSpec(
                                                            style: baseSpec.style,
                                                            isEnabled: baseSpec.isEnabled,
                                                            descriptor: descriptor,
                                                            makeFetchContext: baseSpec.makeFetchContext)
                                                        return store
                                                    }

                                                    await store.refreshProvider(.claude)
                                                    let result = await MainActor.run {
                                                        (
                                                            hasSnapshot: store.snapshot(for: .claude) != nil,
                                                            hasError: store.error(for: .claude) != nil)
                                                    }

                                                    #expect(!result.hasSnapshot)
                                                    #expect(result.hasError)
                                                }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `keychain removal clears prior Claude snapshot for transient failure`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            let storedFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "old")
            let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore(
                fingerprint: storedFingerprint)
            let keychainStore = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(data: nil, fingerprint: nil)

            try await ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(
                fingerprintStore)
            {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                        try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                            try await ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(true) {
                                try await ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(
                                    keychainStore)
                                {
                                    try await ClaudeOAuthCredentialsStore
                                        .withIsolatedCredentialsFileTrackingForTesting {
                                            let tempDir = FileManager.default.temporaryDirectory
                                                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                                            try FileManager.default.createDirectory(
                                                at: tempDir,
                                                withIntermediateDirectories: true)
                                            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

                                            try await ClaudeOAuthCredentialsStore
                                                .withCredentialsURLOverrideForTesting(fileURL) {
                                                    let store = try await MainActor.run {
                                                        let settings = Self.makeSettingsStore(
                                                            suite: "ClaudeResilienceTests-keychain-auth-removal")
                                                        settings.refreshFrequency = .manual
                                                        settings.statusChecksEnabled = false
                                                        settings.claudeUsageDataSource = .cli

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
                                                        let prior = UsageSnapshot(
                                                            primary: RateWindow(
                                                                usedPercent: 12,
                                                                windowMinutes: 300,
                                                                resetsAt: nil,
                                                                resetDescription: nil),
                                                            secondary: nil,
                                                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                            identity: ProviderIdentitySnapshot(
                                                                providerID: .claude,
                                                                accountEmail: "old@example.com",
                                                                accountOrganization: nil,
                                                                loginMethod: "Pro"))
                                                        store._setSnapshotForTesting(prior, provider: .claude)

                                                        let baseSpec = try #require(store.providerSpecs[.claude])
                                                        let descriptor = ProviderDescriptor(
                                                            id: .claude,
                                                            metadata: baseSpec.descriptor.metadata,
                                                            branding: baseSpec.descriptor.branding,
                                                            tokenCost: baseSpec.descriptor.tokenCost,
                                                            fetchPlan: ProviderFetchPlan(
                                                                sourceModes: [.cli],
                                                                pipeline: ProviderFetchPipeline { _ in
                                                                    [TimeoutFetchStrategy()]
                                                                }),
                                                            cli: baseSpec.descriptor.cli)
                                                        store.providerSpecs[.claude] = ProviderSpec(
                                                            style: baseSpec.style,
                                                            isEnabled: baseSpec.isEnabled,
                                                            descriptor: descriptor,
                                                            makeFetchContext: baseSpec.makeFetchContext)
                                                        return store
                                                    }

                                                    await store.refreshProvider(.claude)
                                                    let result = await MainActor.run {
                                                        (
                                                            hasSnapshot: store.snapshot(for: .claude) != nil,
                                                            hasError: store.error(for: .claude) != nil,
                                                            storedFingerprint: fingerprintStore.fingerprint)
                                                    }

                                                    #expect(!result.hasSnapshot)
                                                    #expect(result.hasError)
                                                    #expect(result.storedFingerprint == nil)
                                                }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension ClaudeResilienceTests {
    @Test
    func `keychain probe denial preserves prior Claude snapshot for transient failure`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            let storedFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "old")
            let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore(
                fingerprint: storedFingerprint)
            let deniedStore = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
            deniedStore.deniedUntil = Date(timeIntervalSinceNow: 3600)

            try await ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(
                fingerprintStore)
            {
                try await ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(deniedStore) {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                            let tempDir = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

                            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                                let (store, prior) = try await MainActor.run {
                                    let settings = Self.makeSettingsStore(
                                        suite: "ClaudeResilienceTests-keychain-denial")
                                    settings.refreshFrequency = .manual
                                    settings.statusChecksEnabled = false
                                    settings.claudeUsageDataSource = .cli

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
                                    let prior = UsageSnapshot(
                                        primary: RateWindow(
                                            usedPercent: 12,
                                            windowMinutes: 300,
                                            resetsAt: nil,
                                            resetDescription: nil),
                                        secondary: nil,
                                        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                        identity: ProviderIdentitySnapshot(
                                            providerID: .claude,
                                            accountEmail: "old@example.com",
                                            accountOrganization: nil,
                                            loginMethod: "Pro"))
                                    store._setSnapshotForTesting(prior, provider: .claude)

                                    let baseSpec = try #require(store.providerSpecs[.claude])
                                    let descriptor = ProviderDescriptor(
                                        id: .claude,
                                        metadata: baseSpec.descriptor.metadata,
                                        branding: baseSpec.descriptor.branding,
                                        tokenCost: baseSpec.descriptor.tokenCost,
                                        fetchPlan: ProviderFetchPlan(
                                            sourceModes: [.cli],
                                            pipeline: ProviderFetchPipeline { _ in [TimeoutFetchStrategy()] }),
                                        cli: baseSpec.descriptor.cli)
                                    store.providerSpecs[.claude] = ProviderSpec(
                                        style: baseSpec.style,
                                        isEnabled: baseSpec.isEnabled,
                                        descriptor: descriptor,
                                        makeFetchContext: baseSpec.makeFetchContext)
                                    return (store, prior)
                                }

                                await store.refreshProvider(.claude)
                                let result = await MainActor.run {
                                    (
                                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                                        hasError: store.error(for: .claude) != nil,
                                        storedFingerprint: fingerprintStore.fingerprint)
                                }

                                #expect(result.updatedAt == prior.updatedAt)
                                #expect(!result.hasError)
                                #expect(result.storedFingerprint == storedFingerprint)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `keychain change clears once then preserves later reset backfill`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            let resetDate = Date(timeIntervalSince1970: 1_900_000_000)
            let storedFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "old")
            let currentFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 1,
                persistentRefHash: "new")
            let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore(
                fingerprint: storedFingerprint)

            try await ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(
                fingerprintStore)
            {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                        try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                            try await ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(true) {
                                try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: currentFingerprint)
                                {
                                    try await ClaudeOAuthCredentialsStore
                                        .withIsolatedCredentialsFileTrackingForTesting {
                                            let tempDir = FileManager.default.temporaryDirectory
                                                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                                            try FileManager.default.createDirectory(
                                                at: tempDir,
                                                withIntermediateDirectories: true)
                                            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

                                            try await ClaudeOAuthCredentialsStore
                                                .withCredentialsURLOverrideForTesting(fileURL) {
                                                    let store = try await MainActor.run {
                                                        let settings = Self.makeSettingsStore(
                                                            suite: "ClaudeResilienceTests-keychain-auth-consumed")
                                                        settings.refreshFrequency = .manual
                                                        settings.statusChecksEnabled = false
                                                        settings.claudeUsageDataSource = .cli

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
                                                        let prior = UsageSnapshot(
                                                            primary: RateWindow(
                                                                usedPercent: 12,
                                                                windowMinutes: 300,
                                                                resetsAt: resetDate,
                                                                resetDescription: "old reset"),
                                                            secondary: nil,
                                                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                            identity: nil)
                                                        store._setSnapshotForTesting(prior, provider: .claude)
                                                        store.lastKnownResetSnapshots[.claude] = prior

                                                        let baseSpec = try #require(store.providerSpecs[.claude])
                                                        let descriptor = ProviderDescriptor(
                                                            id: .claude,
                                                            metadata: baseSpec.descriptor.metadata,
                                                            branding: baseSpec.descriptor.branding,
                                                            tokenCost: baseSpec.descriptor.tokenCost,
                                                            fetchPlan: ProviderFetchPlan(
                                                                sourceModes: [.cli],
                                                                pipeline: ProviderFetchPipeline { _ in
                                                                    [SuccessfulFetchStrategy()]
                                                                }),
                                                            cli: baseSpec.descriptor.cli)
                                                        store.providerSpecs[.claude] = ProviderSpec(
                                                            style: baseSpec.style,
                                                            isEnabled: baseSpec.isEnabled,
                                                            descriptor: descriptor,
                                                            makeFetchContext: baseSpec.makeFetchContext)
                                                        return store
                                                    }

                                                    await store.refreshProvider(.claude)
                                                    let firstReset = await MainActor.run {
                                                        store.snapshot(for: .claude)?.primary?.resetsAt
                                                    }
                                                    #expect(firstReset == nil)
                                                    #expect(fingerprintStore.fingerprint == currentFingerprint)

                                                    await MainActor.run {
                                                        let seed = UsageSnapshot(
                                                            primary: RateWindow(
                                                                usedPercent: 10,
                                                                windowMinutes: 300,
                                                                resetsAt: resetDate,
                                                                resetDescription: "fresh reset"),
                                                            secondary: nil,
                                                            updatedAt: Date(timeIntervalSince1970: 1_800_000_050),
                                                            identity: nil)
                                                        store.lastKnownResetSnapshots[.claude] = seed
                                                    }

                                                    await store.refreshProvider(.claude)
                                                    let secondReset = await MainActor.run {
                                                        store.snapshot(for: .claude)?.primary?.resetsAt
                                                    }

                                                    #expect(secondReset == resetDate)
                                                }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `credentials change before fetch clears stale reset backfill`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try Data("{\"old\":true}".utf8).write(to: fileURL)

                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())
                    try Data("{\"new\":true,\"version\":2}".utf8).write(to: fileURL)

                    let store = try await MainActor.run {
                        let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-prefetch-auth-change")
                        settings.refreshFrequency = .manual
                        settings.statusChecksEnabled = false
                        settings.claudeUsageDataSource = .cli

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
                        let prior = UsageSnapshot(
                            primary: RateWindow(
                                usedPercent: 12,
                                windowMinutes: 300,
                                resetsAt: Date(timeIntervalSince1970: 1_900_000_000),
                                resetDescription: "old reset"),
                            secondary: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            identity: nil)
                        store._setSnapshotForTesting(prior, provider: .claude)
                        store.lastKnownResetSnapshots[.claude] = prior

                        let baseSpec = try #require(store.providerSpecs[.claude])
                        let descriptor = ProviderDescriptor(
                            id: .claude,
                            metadata: baseSpec.descriptor.metadata,
                            branding: baseSpec.descriptor.branding,
                            tokenCost: baseSpec.descriptor.tokenCost,
                            fetchPlan: ProviderFetchPlan(
                                sourceModes: [.cli],
                                pipeline: ProviderFetchPipeline { _ in [SuccessfulFetchStrategy()] }),
                            cli: baseSpec.descriptor.cli)
                        store.providerSpecs[.claude] = ProviderSpec(
                            style: baseSpec.style,
                            isEnabled: baseSpec.isEnabled,
                            descriptor: descriptor,
                            makeFetchContext: baseSpec.makeFetchContext)
                        return store
                    }

                    await store.refreshProvider(.claude)
                    let reset = await MainActor.run {
                        store.snapshot(for: .claude)?.primary?.resetsAt
                    }

                    #expect(reset == nil)
                }
            }
        }
    }

    @Test
    func `credentials change during successful Claude fetch applies fresh snapshot without stale reset`() async throws {
        try await KeychainCacheStore.withServiceOverrideForTesting("com.steipete.codexbar.cache.tests.\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try Data("{\"old\":true}".utf8).write(to: fileURL)

                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())

                    let store = try await MainActor.run {
                        let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-midfetch-auth-change")
                        settings.refreshFrequency = .manual
                        settings.statusChecksEnabled = false
                        settings.claudeUsageDataSource = .cli

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
                        let prior = UsageSnapshot(
                            primary: RateWindow(
                                usedPercent: 12,
                                windowMinutes: 300,
                                resetsAt: Date(timeIntervalSince1970: 1_900_000_000),
                                resetDescription: "old reset"),
                            secondary: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            identity: ProviderIdentitySnapshot(
                                providerID: .claude,
                                accountEmail: "old@example.com",
                                accountOrganization: nil,
                                loginMethod: "Pro"))
                        store._setSnapshotForTesting(prior, provider: .claude)
                        store.lastKnownResetSnapshots[.claude] = prior

                        let baseSpec = try #require(store.providerSpecs[.claude])
                        let descriptor = ProviderDescriptor(
                            id: .claude,
                            metadata: baseSpec.descriptor.metadata,
                            branding: baseSpec.descriptor.branding,
                            tokenCost: baseSpec.descriptor.tokenCost,
                            fetchPlan: ProviderFetchPlan(
                                sourceModes: [.cli],
                                pipeline: ProviderFetchPipeline { _ in
                                    [SuccessfulCredentialSwapFetchStrategy(credentialsFileURL: fileURL)]
                                }),
                            cli: baseSpec.descriptor.cli)
                        store.providerSpecs[.claude] = ProviderSpec(
                            style: baseSpec.style,
                            isEnabled: baseSpec.isEnabled,
                            descriptor: descriptor,
                            makeFetchContext: baseSpec.makeFetchContext)
                        return store
                    }

                    await store.refreshProvider(.claude)
                    let result = await MainActor.run {
                        (
                            hasSnapshot: store.snapshot(for: .claude) != nil,
                            hasError: store.error(for: .claude) != nil,
                            reset: store.lastKnownResetSnapshots[.claude]?.primary?.resetsAt)
                    }

                    #expect(result.hasSnapshot)
                    #expect(!result.hasError)
                    #expect(result.reset == nil)
                }
            }
        }
    }

    @MainActor
    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
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
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }
}

private struct TimeoutFetchStrategy: ProviderFetchStrategy {
    let id = "test.timeout"
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

private struct CancellationFetchStrategy: ProviderFetchStrategy {
    let id = "test.cancellation"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw CancellationError()
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct CancellationAfterCredentialSwapFetchStrategy: ProviderFetchStrategy {
    let id = "test.cancelled-credential-swap"
    let kind: ProviderFetchKind = .cli
    let cancellations: CredentialSwapCancellationSequence

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.cancellations.fetch()
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor CredentialSwapCancellationSequence {
    private struct StartWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let credentialsFileURL: URL
    private var starts = 0
    private var startWaiters: [StartWaiter] = []

    init(credentialsFileURL: URL) {
        self.credentialsFileURL = credentialsFileURL
    }

    func fetch() async throws -> ProviderFetchResult {
        self.starts += 1
        let call = self.starts
        self.resumeReadyStartWaiters()
        if call == 1 {
            try Data("{\"updated\":true}".utf8).write(to: self.credentialsFileURL)
            try await Task.sleep(for: .seconds(60))
        }
        throw CancellationError()
    }

    func waitUntilStarted(count: Int) async {
        guard self.starts < count else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(StartWaiter(count: count, continuation: continuation))
        }
    }

    private func resumeReadyStartWaiters() {
        let ready = self.startWaiters.filter { $0.count <= self.starts }
        self.startWaiters.removeAll { $0.count <= self.starts }
        ready.forEach { $0.continuation.resume() }
    }
}

private struct NetworkLostFetchStrategy: ProviderFetchStrategy {
    let id = "test.network-lost"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw URLError(.networkConnectionLost)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct AuthFailureFetchStrategy: ProviderFetchStrategy {
    let id = "test.auth-failure"
    let kind: ProviderFetchKind = .cli
    let credentialsFileURL: URL

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Data("{\"updated\":true}".utf8).write(to: self.credentialsFileURL)
        _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
        throw ClaudeUsageError.oauthFailed("Claude auth failed.")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct TransientFailureAfterCredentialSwapFetchStrategy: ProviderFetchStrategy {
    let id = "test.transient-credential-swap"
    let kind: ProviderFetchKind = .cli
    let credentialsFileURL: URL

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Data("{\"updated\":true}".utf8).write(to: self.credentialsFileURL)
        throw ClaudeStatusProbeError.timedOut
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct SuccessfulCredentialSwapFetchStrategy: ProviderFetchStrategy {
    let id = "test.successful-credential-swap"
    let kind: ProviderFetchKind = .cli
    let credentialsFileURL: URL

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Data("{\"updated\":true}".utf8).write(to: self.credentialsFileURL)
        return self.makeResult(
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                identity: nil),
            sourceLabel: "CLI")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct SuccessfulFetchStrategy: ProviderFetchStrategy {
    let id = "test.successful"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        self.makeResult(
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                identity: nil),
            sourceLabel: "CLI")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

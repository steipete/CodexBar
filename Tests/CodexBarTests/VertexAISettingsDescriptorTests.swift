import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct VertexAISettingsDescriptorTests {
    private static func makeIsolatedSettings(
        defaults: UserDefaults,
        configStore: CodexBarConfigStore) -> SettingsStore
    {
        SettingsStore(
            userDefaults: defaults,
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
            tokenAccountStore: InMemoryTokenAccountStore(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
    }

    @Test
    func `vertexai settings expose descriptors persist across reopen and populate settingsSnapshot`() async throws {
        let suite = "VertexAISettingsDescriptorTests-persist-\(UUID().uuidString)"
        let configStore = testConfigStore(suiteName: suite, reset: true)
        let defaults = InMemoryUserDefaults()
        let settings = Self.makeIsolatedSettings(defaults: defaults, configStore: configStore)
        defer {
            settings.configPersistTask?.cancel()
            settings.configFileWatcher?.stop()
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let context = ProviderSettingsContext(
            provider: .vertexai,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let impl = VertexAIProviderImplementation()

        let pickers = impl.settingsPickers(context: context)
        let fields = impl.settingsFields(context: context)
        let toggles = impl.settingsToggles(context: context)

        let metricPicker = try #require(pickers.first { $0.id == "vertexai-primary-bar-metric" })
        let sourcePicker = try #require(pickers.first { $0.id == "vertexai-telemetry-cost-source" })
        let regionPicker = try #require(pickers.first { $0.id == "vertexai-region-filter" })
        let projectField = try #require(fields.first { $0.id == "vertexai-project-id-override" })
        let modelField = try #require(fields.first { $0.id == "vertexai-model-filter" })
        let fallbackToggle = try #require(toggles.first { $0.id == "vertexai-allow-claude-fallback" })
        let estimateToggle = try #require(toggles.first { $0.id == "vertexai-estimate-cloud-cost" })

        #expect(metricPicker.binding.wrappedValue == VertexAIPrimaryBarMetric.auto.rawValue)
        #expect(sourcePicker.binding.wrappedValue == VertexAITelemetryCostSource.auto.rawValue)
        #expect(regionPicker.binding.wrappedValue == VertexAIRegionFilterOption.all.rawValue)
        #expect(projectField.binding.wrappedValue.isEmpty)
        #expect(modelField.binding.wrappedValue.isEmpty)
        #expect(fallbackToggle.binding.wrappedValue == false)
        #expect(estimateToggle.binding.wrappedValue == false)

        metricPicker.binding.wrappedValue = VertexAIPrimaryBarMetric.rateQuota.rawValue
        sourcePicker.binding.wrappedValue = VertexAITelemetryCostSource.cloudMonitoringOnly.rawValue
        regionPicker.binding.wrappedValue = "us-east5"
        projectField.binding.wrappedValue = "  prod-vertex-123  "
        modelField.binding.wrappedValue = "claude-sonnet-4-6"
        fallbackToggle.binding.wrappedValue = true
        estimateToggle.binding.wrappedValue = true
        _ = await settings.configPersistTask?.result

        let expectedSettings = VertexAIProviderSettings(
            projectIDOverride: "prod-vertex-123",
            regionFilter: "us-east5",
            modelFilter: "claude-sonnet-4-6",
            primaryBarMetric: .rateQuota,
            telemetryCostSource: .cloudMonitoringOnly,
            allowClaudeFallback: true,
            estimateCloudCost: true)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            provider: .vertexai,
            settings: settings,
            tokenOverride: nil)
        #expect(snapshot.vertexai == expectedSettings)

        let reopenedConfigStore = testConfigStore(suiteName: suite, reset: false)
        let reopenedConfig = try #require(try reopenedConfigStore.load())
        let reopenedSettings = Self.makeIsolatedSettings(defaults: defaults, configStore: reopenedConfigStore)
        defer {
            reopenedSettings.configPersistTask?.cancel()
            reopenedSettings.configFileWatcher?.stop()
        }
        #expect(reopenedSettings.vertexAISettingsSnapshot() == expectedSettings)

        let cliContribution = try #require(VertexAIProviderDescriptor.descriptor.settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(
                config: reopenedConfig.providerConfig(for: .vertexai),
                account: nil)))
        let cliSnapshot = ProviderSettingsSnapshot(contributions: [cliContribution])
        #expect(cliSnapshot.vertexai == expectedSettings)
    }

    @Test
    func `tokenSnapshotScopeSignature invalidates when any Vertex AI token or filter setting changes`() {
        let suite = "VertexAISettingsDescriptorTests-scope"
        let settings = testSettingsStore(
            suiteName: suite,
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        defer {
            settings.configPersistTask?.cancel()
            settings.configFileWatcher?.stop()
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let s0 = store.tokenSnapshotScopeSignature(for: .vertexai)
        let d0 = store.spendDashboardTokenSnapshotScopeSignature(for: .vertexai)

        settings.vertexAITelemetryCostSource = .localClaudeLogsOnly
        let s1 = store.tokenSnapshotScopeSignature(for: .vertexai)
        #expect(s1 != s0)
        #expect(store.spendDashboardTokenSnapshotScopeSignature(for: .vertexai) != d0)

        settings.vertexAIAllowClaudeFallback = true
        let s2 = store.tokenSnapshotScopeSignature(for: .vertexai)
        #expect(s2 != s1)

        settings.vertexAIEstimateCloudCost = true
        let s3 = store.tokenSnapshotScopeSignature(for: .vertexai)
        #expect(s3 != s2)

        settings.vertexAIProjectIDOverride = "custom-proj"
        let s4 = store.tokenSnapshotScopeSignature(for: .vertexai)
        #expect(s4 != s3)

        settings.vertexAIRegionFilter = "us-central1"
        let s5 = store.tokenSnapshotScopeSignature(for: .vertexai)
        #expect(s5 != s4)

        settings.vertexAIModelFilter = "gemini-2.5-pro"
        let s6 = store.tokenSnapshotScopeSignature(for: .vertexai)
        #expect(s6 != s5)
    }

    @Test
    func `ProviderIntentPayload round-trips Vertex AI settings and preserves defaults for legacy senders`() throws {
        var config = ProviderConfig(id: .vertexai)
        config.vertexAIProjectIDOverride = "sync-proj"
        config.vertexAIRegionFilter = "europe-west1"
        config.vertexAIModelFilter = "gemini-2.5-pro"
        config.vertexAIPrimaryBarMetric = VertexAIPrimaryBarMetric.allocationQuota.rawValue
        config.vertexAITelemetryCostSource = VertexAITelemetryCostSource.localClaudeLogsOnly.rawValue
        config.vertexAIAllowClaudeFallback = true
        config.vertexAIEstimateCloudCost = true

        let payload = ProviderIntentPayload(config: config)
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ProviderIntentPayload.self, from: encoded)
        let applied = try decoded.applying(
            to: ProviderConfig(id: .vertexai),
            secretFields: [:],
            canEnable: { _, _ in true })

        #expect(applied.resolvedVertexAISettings == VertexAIProviderSettings(
            projectIDOverride: "sync-proj",
            regionFilter: "europe-west1",
            modelFilter: "gemini-2.5-pro",
            primaryBarMetric: .allocationQuota,
            telemetryCostSource: .localClaudeLogsOnly,
            allowClaudeFallback: true,
            estimateCloudCost: true))

        // Legacy payload lacking vertexAI* fields must not overwrite existing local settings.
        let legacyJSON = #"{"schemaVersion":1,"provider":"vertexai"}"#
        let legacyPayload = try JSONDecoder().decode(ProviderIntentPayload.self, from: Data(legacyJSON.utf8))
        let preserved = try legacyPayload.applying(
            to: applied,
            secretFields: [:],
            canEnable: { _, _ in true })
        #expect(preserved.resolvedVertexAISettings == applied.resolvedVertexAISettings)

        // Clearing settings back to defaults on Mac A must clear Mac B's non-default settings.
        let clearedConfig = ProviderConfig(id: .vertexai)
        let clearPayload = ProviderIntentPayload(config: clearedConfig)
        let clearData = try JSONEncoder().encode(clearPayload)
        let decodedClear = try JSONDecoder().decode(ProviderIntentPayload.self, from: clearData)
        let clearedOnTarget = try decodedClear.applying(
            to: applied,
            secretFields: [:],
            canEnable: { _, _ in true })
        #expect(clearedOnTarget.resolvedVertexAISettings == VertexAIProviderSettings())
        #expect(clearedOnTarget.vertexAIProjectIDOverride == nil)
        #expect(clearedOnTarget.vertexAIRegionFilter == nil)
        #expect(clearedOnTarget.vertexAIModelFilter == nil)
        #expect(clearedOnTarget.vertexAIPrimaryBarMetric == nil)
        #expect(clearedOnTarget.vertexAITelemetryCostSource == nil)
        #expect(clearedOnTarget.vertexAIAllowClaudeFallback == nil)
        #expect(clearedOnTarget.vertexAIEstimateCloudCost == nil)
    }
}

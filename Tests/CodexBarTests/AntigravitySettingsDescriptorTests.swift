import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AntigravitySettingsDescriptorTests {
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
    func `antigravity settings expose descriptors persist across reopen and populate settingsSnapshot`() async throws {
        let suite = "AntigravitySettingsDescriptorTests-persist-\(UUID().uuidString)"
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
            provider: .antigravity,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let impl = AntigravityProviderImplementation()

        let pickers = impl.settingsPickers(context: context)
        let toggles = impl.settingsToggles(context: context)
        let poolPicker = try #require(pickers.first { $0.id == "antigravity-primary-pool" })
        let groupingPicker = try #require(pickers.first { $0.id == "antigravity-project-grouping" })
        let creditsToggle = try #require(toggles.first { $0.id == "antigravity-show-credits" })
        let desktopToggle = try #require(toggles.first { $0.id == "antigravity-scan-desktop" })
        let cliToggle = try #require(toggles.first { $0.id == "antigravity-scan-cli" })
        let tokscaleToggle = try #require(toggles.first { $0.id == "antigravity-tokscale-fallback" })

        #expect(poolPicker.binding.wrappedValue == AntigravityPrimaryPoolPreference.auto.rawValue)
        #expect(groupingPicker.binding.wrappedValue == AntigravityProjectGrouping.workspace.rawValue)
        #expect(creditsToggle.binding.wrappedValue == true)
        #expect(desktopToggle.binding.wrappedValue == true)
        #expect(cliToggle.binding.wrappedValue == true)
        #expect(tokscaleToggle.binding.wrappedValue == true)

        poolPicker.binding.wrappedValue = AntigravityPrimaryPoolPreference.claudeGPTWeekly.rawValue
        groupingPicker.binding.wrappedValue = AntigravityProjectGrouping.gitRepository.rawValue
        creditsToggle.binding.wrappedValue = false
        desktopToggle.binding.wrappedValue = false
        cliToggle.binding.wrappedValue = true
        tokscaleToggle.binding.wrappedValue = false
        _ = await settings.configPersistTask?.result

        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            provider: .antigravity,
            settings: settings,
            tokenOverride: nil)
        #expect(snapshot.antigravity == AntigravityProviderSettings(
            primaryPoolPreference: .claudeGPTWeekly,
            showCredits: false))

        let reopenedConfigStore = testConfigStore(suiteName: suite, reset: false)
        let reopenedConfig = try #require(try reopenedConfigStore.load())
        let reopenedSettings = Self.makeIsolatedSettings(defaults: defaults, configStore: reopenedConfigStore)
        defer {
            reopenedSettings.configPersistTask?.cancel()
            reopenedSettings.configFileWatcher?.stop()
        }
        #expect(reopenedSettings.antigravityPrimaryPoolPreference == .claudeGPTWeekly)
        #expect(reopenedSettings.antigravityProjectGrouping == .gitRepository)
        #expect(reopenedSettings.antigravityShowCredits == false)
        #expect(reopenedSettings.antigravityScanDesktopEnabled == false)
        #expect(reopenedSettings.antigravityScanCLIEnabled == true)
        #expect(reopenedSettings.antigravityTokscaleFallbackEnabled == false)

        let cliContribution = try #require(AntigravityProviderDescriptor.descriptor.settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(
                config: reopenedConfig.providerConfig(for: .antigravity),
                account: nil)))
        let cliSnapshot = ProviderSettingsSnapshot(contributions: [cliContribution])
        #expect(cliSnapshot.antigravity == AntigravityProviderSettings(
            primaryPoolPreference: .claudeGPTWeekly,
            showCredits: false))
    }

    @Test
    func `menuBarWindow and MenuBarMetricWindowResolver honor primaryPoolPreference with safe fallback`() throws {
        let json = antigravityQuotaSummaryJSON(
            geminiSession: 0.90,
            geminiWeekly: 0.75,
            claudeSession: 0.50,
            claudeWeekly: 0.25)
        let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()

        let autoWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false)
        #expect(autoWindow?.remainingPercent.rounded() == 25)

        let geminiWeeklyWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false,
            antigravityPrimaryPool: .geminiWeekly)
        #expect(geminiWeeklyWindow?.remainingPercent.rounded() == 75)

        let geminiFiveHourWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false,
            antigravityPrimaryPool: .geminiFiveHour)
        #expect(geminiFiveHourWindow?.remainingPercent.rounded() == 90)

        let claudeFiveHourWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false,
            antigravityPrimaryPool: .claudeGPTFiveHour)
        #expect(claudeFiveHourWindow?.remainingPercent.rounded() == 50)

        let weeklyOnlyJSON = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit",
                    "remainingFraction": 0.80,
                    "resetTime": "2026-12-07T00:00:00Z"
                  }
                ]
              },
              {
                "displayName": "Claude / GPT Models",
                "buckets": [
                  {
                    "bucketId": "claude-gpt-weekly",
                    "displayName": "Weekly Limit",
                    "remainingFraction": 0.60,
                    "resetTime": "2026-12-07T00:00:00Z"
                  }
                ]
              }
            ]
          }
        }
        """
        let weeklyOnlyUsage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(weeklyOnlyJSON.utf8))
            .toUsageSnapshot()
        let missingFiveHourFallback = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: weeklyOnlyUsage,
            supportsAverage: false,
            antigravityPrimaryPool: .geminiFiveHour)
        #expect(missingFiveHourFallback?.remainingPercent.rounded() == 60)
    }

    @Test
    func `tokenSnapshotScopeSignature invalidates when scan source toggles or project grouping change`() {
        let suite = "AntigravitySettingsDescriptorTests-scope"
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
            environmentBase: ["HOME": "/Synthetic/AntigravityScope"])

        let initialTokenSig = store.tokenSnapshotScopeSignature(for: .antigravity)
        let initialSpendSig = store.spendDashboardTokenSnapshotScopeSignature(for: .antigravity)

        settings.antigravityScanDesktopEnabled = false
        let afterDesktopSig = store.tokenSnapshotScopeSignature(for: .antigravity)
        #expect(afterDesktopSig != initialTokenSig)
        #expect(store.spendDashboardTokenSnapshotScopeSignature(for: .antigravity) != initialSpendSig)

        settings.antigravityScanCLIEnabled = false
        let afterCLISig = store.tokenSnapshotScopeSignature(for: .antigravity)
        #expect(afterCLISig != afterDesktopSig)

        settings.antigravityTokscaleFallbackEnabled = false
        let afterTokscaleSig = store.tokenSnapshotScopeSignature(for: .antigravity)
        #expect(afterTokscaleSig != afterCLISig)

        settings.antigravityProjectGrouping = .gitRepository
        let afterGroupingSig = store.tokenSnapshotScopeSignature(for: .antigravity)
        #expect(afterGroupingSig != afterTokscaleSig)
    }

    @Test
    func `ProviderIntentPayload round-trips portable Antigravity settings cleanly`() throws {
        var config = ProviderConfig(id: .antigravity)
        config.antigravityPrimaryPoolPreference = AntigravityPrimaryPoolPreference.geminiWeekly.rawValue
        config.antigravityShowCredits = false
        config.antigravityScanDesktopEnabled = false
        config.antigravityScanCLIEnabled = true
        config.antigravityTokscaleFallbackEnabled = false
        config.antigravityProjectGrouping = AntigravityProjectGrouping.gitRepository.rawValue

        let payload = ProviderIntentPayload(config: config)
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ProviderIntentPayload.self, from: encoded)
        let applied = try decoded.applying(
            to: ProviderConfig(id: .antigravity),
            secretFields: [:],
            canEnable: { _, _ in true })

        #expect(applied.resolvedAntigravityPrimaryPoolPreference == .geminiWeekly)
        #expect(applied.antigravityShowCredits == false)
        #expect(applied.antigravityScanDesktopEnabled == false)
        #expect(applied.antigravityScanCLIEnabled == true)
        #expect(applied.antigravityTokscaleFallbackEnabled == false)
        #expect(applied.resolvedAntigravityProjectGrouping == .gitRepository)
    }
}

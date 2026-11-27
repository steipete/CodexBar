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
    func `quotaSummary preserves non-inverted rateWindowLabels when Claude GPT pool is preferred`() throws {
        let json = antigravityQuotaSummaryJSON(
            geminiSession: 0.90,
            geminiWeekly: 0.75,
            claudeSession: 0.50,
            claudeWeekly: 0.25)
        let summary = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8))
        let metadata = AntigravityProviderDescriptor.descriptor.metadata

        for (pool, expectedWindowID, expectedMenuBarUsed): (AntigravityPrimaryPoolPreference, String, Double) in [
            (.claudeGPTWeekly, "antigravity-quota-summary-3p-weekly", 75),
            (.claudeGPTFiveHour, "antigravity-quota-summary-3p-5h", 50),
        ] {
            let usage = try summary.toUsageSnapshot(primaryPool: pool)
            #expect(usage.extraRateWindows?.first?.id == expectedWindowID)
            #expect(usage.primary?.usedPercent.rounded() == 25)
            #expect(usage.secondary?.usedPercent.rounded() == 75)

            let labels = AntigravityProviderDescriptor.descriptor.presentation.rateWindowLabels(
                metadata: metadata,
                snapshot: usage)
            #expect(labels.primary == "Gemini Models")
            #expect(labels.secondary == "Claude and GPT")

            let menuBar = MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: .antigravity,
                snapshot: usage,
                supportsAverage: false,
                antigravityPrimaryPool: pool)
            #expect(menuBar?.usedPercent.rounded() == expectedMenuBarUsed)

            let cardModel = UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: usage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: Date(timeIntervalSince1970: 1_787_832_000)))
            let expectedLeadTitle = pool == .claudeGPTWeekly ? "Claude/GPT weekly" : "Claude/GPT 5-hour"
            #expect(cardModel.metrics.first?.title == expectedLeadTitle)
        }
    }

    @Test
    func `explicitly selected idle Claude GPT pool stays visible and leads menu card while Auto hides it`() throws {
        let json = antigravityQuotaSummaryJSON(
            geminiSession: 0.90,
            geminiWeekly: 0.75,
            claudeSession: 1.0,
            claudeWeekly: 1.0)
        let summary = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8))
        let metadata = AntigravityProviderDescriptor.descriptor.metadata
        let now = Date(timeIntervalSince1970: 1_787_832_000)

        let autoUsage = try summary.toUsageSnapshot(primaryPool: .auto)
        #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: autoUsage) == [
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
        ])
        let autoCard = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: metadata,
            snapshot: autoUsage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        #expect(autoCard.metrics.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
        ])

        let cases: [(AntigravityPrimaryPoolPreference, String, String)] = [
            (.claudeGPTWeekly, "antigravity-quota-summary-3p-weekly", "Claude/GPT weekly"),
            (.claudeGPTFiveHour, "antigravity-quota-summary-3p-5h", "Claude/GPT 5-hour"),
        ]
        for (pool, expectedWindowID, expectedLeadTitle) in cases {
            let usage = try summary.toUsageSnapshot(primaryPool: pool)
            #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage).isEmpty)

            let menuBar = MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: .antigravity,
                snapshot: usage,
                supportsAverage: false,
                antigravityPrimaryPool: pool)
            #expect(menuBar?.usedPercent.rounded() == 0)

            let cardModel = UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: usage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
            #expect(cardModel.metrics.first?.id == expectedWindowID)
            #expect(cardModel.metrics.first?.title == expectedLeadTitle)
            #expect(cardModel.metrics.contains(where: { $0.id == "antigravity-quota-summary-3p-5h" }))
            #expect(cardModel.metrics.contains(where: { $0.id == "antigravity-quota-summary-3p-weekly" }))

            // Live setting override on an Auto-fetched snapshot also keeps the selected idle pool visible and first.
            let overrideCard = UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: autoUsage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                antigravityPrimaryPool: pool,
                hidePersonalInfo: false,
                now: now))
            #expect(overrideCard.metrics.first?.id == expectedWindowID)
            #expect(overrideCard.metrics.first?.title == expectedLeadTitle)

            // Switching live setting back to Auto hides the idle family again even before the next refresh.
            let revertedToAutoCard = UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: usage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                antigravityPrimaryPool: .auto,
                hidePersonalInfo: false,
                now: now))
            #expect(revertedToAutoCard.metrics.map(\.id) == [
                "antigravity-quota-summary-gemini-5h",
                "antigravity-quota-summary-gemini-weekly",
            ])
        }
    }

    @Test
    func `modelQuotas snapshot honors primaryPoolPreference in menuBarWindow without mislabeling card`() throws {
        let now = Date(timeIntervalSince1970: 1_787_832_000)
        let reset = now.addingTimeInterval(3600)
        let statusSnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "gemini-3-1-pro-high",
                    remainingFraction: 0.90,
                    resetTime: reset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6",
                    modelId: "claude-sonnet-4-6",
                    remainingFraction: 0.40,
                    resetTime: reset,
                    resetDescription: nil),
            ],
            accountEmail: "modelquotas@example.com",
            accountPlan: "Pro",
            source: .remote)

        let usage = try statusSnapshot.toUsageSnapshot(primaryPool: .claudeGPTWeekly)
        #expect(usage.primary?.remainingPercent.rounded() == 90)
        #expect(usage.secondary?.remainingPercent.rounded() == 40)

        let metadata = try #require(ProviderDefaults.metadata[.antigravity])
        let cardModel = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: metadata,
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        #expect(cardModel.metrics.map(\.title) == ["Gemini Models", "Claude and GPT"])
        #expect(cardModel.metrics.map(\.percentLabel) == ["90% left", "40% left"])

        let claudeWeeklyWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false,
            antigravityPrimaryPool: .claudeGPTWeekly)
        #expect(claudeWeeklyWindow?.usedPercent.rounded() == 60)

        let claudeFiveHourWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false,
            antigravityPrimaryPool: .claudeGPTFiveHour)
        #expect(claudeFiveHourWindow?.usedPercent.rounded() == 60)

        let geminiWeeklyWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: usage,
            supportsAverage: false,
            antigravityPrimaryPool: .geminiWeekly)
        #expect(geminiWeeklyWindow?.usedPercent.rounded() == 10)

        let geminiOnlySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "gemini-3-1-pro-high",
                    remainingFraction: 0.85,
                    resetTime: reset,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: "Pro",
            source: .remote)
        let geminiOnlyUsage = try geminiOnlySnapshot.toUsageSnapshot(primaryPool: .claudeGPTWeekly)
        let fallbackWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: geminiOnlyUsage,
            supportsAverage: false,
            antigravityPrimaryPool: .claudeGPTWeekly)
        #expect(fallbackWindow?.usedPercent.rounded() == 15)
    }

    @Test
    func `fallback card metrics honor explicit antigravityPrimaryPool while preserving family labels and windows`()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_787_832_000)
        let geminiReset = now.addingTimeInterval(3600)
        let claudeReset = now.addingTimeInterval(7200)
        let statusSnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "gemini-3-1-pro-high",
                    remainingFraction: 0.90,
                    resetTime: geminiReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6",
                    modelId: "claude-sonnet-4-6",
                    remainingFraction: 0.40,
                    resetTime: claudeReset,
                    resetDescription: nil),
            ],
            accountEmail: "fallback@example.com",
            accountPlan: "Pro",
            source: .remote)
        let usage = try statusSnapshot.toUsageSnapshot(primaryPool: .auto)
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        func makeCard(pool: AntigravityPrimaryPoolPreference) -> UsageMenuCardView.Model {
            UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: usage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                antigravityPrimaryPool: pool,
                hidePersonalInfo: false,
                now: now))
        }

        let expectedGeminiReset = try UsageFormatter.resetLine(
            for: #require(usage.primary),
            style: .countdown,
            now: now)
        let expectedClaudeReset = try UsageFormatter.resetLine(
            for: #require(usage.secondary),
            style: .countdown,
            now: now)
        #expect(expectedGeminiReset != expectedClaudeReset)

        for pool: AntigravityPrimaryPoolPreference in [.claudeGPTWeekly, .claudeGPTFiveHour] {
            let card = makeCard(pool: pool)
            #expect(card.metrics.map(\.id) == ["secondary", "primary"])
            #expect(card.metrics.map(\.title) == ["Claude and GPT", "Gemini Models"])
            #expect(card.metrics.map(\.percentLabel) == ["40% left", "90% left"])
            #expect(card.metrics.map(\.resetText) == [expectedClaudeReset, expectedGeminiReset])
        }

        for pool: AntigravityPrimaryPoolPreference in [.auto, .geminiWeekly, .geminiFiveHour] {
            let card = makeCard(pool: pool)
            #expect(card.metrics.map(\.id) == ["primary", "secondary"])
            #expect(card.metrics.map(\.title) == ["Gemini Models", "Claude and GPT"])
            #expect(card.metrics.map(\.percentLabel) == ["90% left", "40% left"])
            #expect(card.metrics.map(\.resetText) == [expectedGeminiReset, expectedClaudeReset])
        }
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

    @Test
    func `ProviderIntentPayload syncs Antigravity resets to defaults while preserving legacy nil payloads`() throws {
        var receiving = ProviderConfig(id: .antigravity)
        receiving.antigravityPrimaryPoolPreference = AntigravityPrimaryPoolPreference.claudeGPTWeekly.rawValue
        receiving.antigravityProjectGrouping = AntigravityProjectGrouping.gitRepository.rawValue

        // Resetting back to Auto / Workspace stores nil in ProviderConfig, so the payload must encode
        // explicit defaults.
        let resetSender = ProviderConfig(id: .antigravity)
        #expect(resetSender.antigravityPrimaryPoolPreference == nil)
        #expect(resetSender.antigravityProjectGrouping == nil)

        let resetPayload = ProviderIntentPayload(config: resetSender)
        #expect(resetPayload.antigravityPrimaryPoolPreference == AntigravityPrimaryPoolPreference.auto.rawValue)
        #expect(resetPayload.antigravityProjectGrouping == AntigravityProjectGrouping.workspace.rawValue)

        let encoded = try JSONEncoder().encode(resetPayload)
        let decoded = try JSONDecoder().decode(ProviderIntentPayload.self, from: encoded)
        let appliedReset = try decoded.applying(to: receiving, secretFields: [:], canEnable: { _, _ in true })
        #expect(appliedReset.antigravityPrimaryPoolPreference == nil)
        #expect(appliedReset.resolvedAntigravityPrimaryPoolPreference == .auto)
        #expect(appliedReset.antigravityProjectGrouping == nil)
        #expect(appliedReset.resolvedAntigravityProjectGrouping == .workspace)

        // Older senders omit these fields entirely; decoding nil must preserve the receiving Mac's values.
        let legacyJSON = #"{"schemaVersion":1,"provider":"antigravity"}"#
        let legacyPayload = try JSONDecoder().decode(ProviderIntentPayload.self, from: Data(legacyJSON.utf8))
        #expect(legacyPayload.antigravityPrimaryPoolPreference == nil)
        #expect(legacyPayload.antigravityProjectGrouping == nil)

        let appliedLegacy = try legacyPayload.applying(to: receiving, secretFields: [:], canEnable: { _, _ in true })
        #expect(appliedLegacy.resolvedAntigravityPrimaryPoolPreference == .claudeGPTWeekly)
        #expect(appliedLegacy.resolvedAntigravityProjectGrouping == .gitRepository)
    }
}

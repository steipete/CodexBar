import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ProviderSettingsDescriptorTests {
    @Test
    func `toggle I ds are unique across providers`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-unique")
        var seenToggleIDs: Set<String> = []
        var seenActionIDs: Set<String> = []
        var seenPickerIDs: Set<String> = []

        for provider in UsageProvider.allCases {
            let context = fixture.settingsContext(provider: provider)
            let impl = try #require(ProviderCatalog.implementation(for: provider))
            let toggles = impl.settingsToggles(context: context)
            for toggle in toggles {
                #expect(!seenToggleIDs.contains(toggle.id))
                seenToggleIDs.insert(toggle.id)

                for action in toggle.actions {
                    #expect(!seenActionIDs.contains(action.id))
                    seenActionIDs.insert(action.id)
                }
            }

            let pickers = impl.settingsPickers(context: context)
            for picker in pickers {
                #expect(!seenPickerIDs.contains(picker.id))
                seenPickerIDs.insert(picker.id)
            }
        }
    }

    @Test
    func `openai exposes project id setting`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-openai-project")
        let context = fixture.settingsContext(provider: .openai)

        let fields = OpenAIAPIProviderImplementation().settingsFields(context: context)
        let project = try #require(fields.first(where: { $0.id == "openai-project-id" }))
        project.binding.wrappedValue = "proj_abc"

        #expect(project.title == "Project ID")
        #expect(project.subtitle.contains(OpenAIAPISettingsReader.projectIDEnvironmentKey))
        #expect(fixture.settings.openAIAPIProjectID == "proj_abc")
        #expect(fixture.settings.providerConfig(for: .openai)?.sanitizedWorkspaceID == "proj_abc")
    }

    @Test
    func `open code cookie refresh commits replacement through user initiated gate`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencode-refresh")
        let context = fixture.settingsContext(provider: .opencode)
        let picker = try #require(OpenCodeProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-refresh.\(UUID().uuidString)"
        var observedInteraction: ProviderInteraction?

        #expect(action.title == "Refresh")
        #expect(action.isVisible?() == true)

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencode,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { provider in
                    observedInteraction = ProviderInteractionContext.current
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "new-test-cookie",
                        sourceLabel: "Test new")
                    fixture.store.snapshots[provider] = UsageSnapshot(
                        primary: nil,
                        secondary: nil,
                        updatedAt: Date())
                    fixture.store.lastSourceLabels[provider] = "web"
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(observedInteraction == .userInitiated)
                #expect(CookieHeaderCache.load(provider: .opencode)?.cookieHeader == "new-test-cookie")
                #expect(picker.trailingText?()?.contains("Test new") == true)
            }
        }
    }

    @Test
    func `open code go cookie refresh rejects local fallback cookie`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencodego-validation")
        let context = fixture.settingsContext(provider: .opencodego)
        let picker = try #require(OpenCodeGoProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-validation.\(UUID().uuidString)"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencodego,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { provider in
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "invalid-test-cookie",
                        sourceLabel: "Test invalid")
                    fixture.store.snapshots[provider] = UsageSnapshot(
                        primary: nil,
                        secondary: nil,
                        updatedAt: Date())
                    fixture.store.lastSourceLabels[provider] = "local"
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(CookieHeaderCache.load(provider: .opencodego)?.cookieHeader == "old-test-cookie")
                #expect(picker.trailingText?() == L("Failed"))
            }
        }
    }

    @Test
    func `open code cookie refresh rejects missing validation snapshot`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencode-validation")
        let context = fixture.settingsContext(provider: .opencode)
        let picker = try #require(OpenCodeProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-missing-snapshot.\(UUID().uuidString)"
        fixture.store.snapshots[.opencode] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date())
        fixture.store.lastSourceLabels[.opencode] = "web"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencode,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { provider in
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "unvalidated-test-cookie",
                        sourceLabel: "Test unvalidated")
                    fixture.store.snapshots.removeValue(forKey: provider)
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(CookieHeaderCache.load(provider: .opencode)?.cookieHeader == "old-test-cookie")
                #expect(picker.trailingText?() == L("Failed"))
            }
        }
    }

    @Test
    func `open code cookie refresh respects denial cooldown and preserves cookie`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-opencode-cooldown")
        let context = fixture.settingsContext(provider: .opencode)
        let picker = try #require(OpenCodeProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-cooldown.\(UUID().uuidString)"
        var cooldownRespected = false

        BrowserCookieAccessGate.resetForTesting()
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        defer { BrowserCookieAccessGate.resetForTesting() }

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .opencode,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")
                fixture.store._test_providerRefreshOverride = { _ in
                    cooldownRespected = !BrowserCookieAccessGate.shouldAttempt(.chrome)
                }
                defer { fixture.store._test_providerRefreshOverride = nil }

                await action.perform()

                #expect(cooldownRespected)
                #expect(CookieHeaderCache.load(provider: .opencode)?.cookieHeader == "old-test-cookie")
                #expect(picker.trailingText?() == L("Failed"))
            }
        }
    }

    @Test
    func `antigravity usage source picker clarifies local ide and agy`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-antigravity-source")
        let context = fixture.settingsContext(provider: .antigravity)

        let pickers = AntigravityProviderImplementation().settingsPickers(context: context)
        let usagePicker = try #require(pickers.first(where: { $0.id == "antigravity-usage-source" }))

        #expect(usagePicker.options.map(\.title) == ["Auto", "Google OAuth", "Local API / agy CLI"])
        #expect(usagePicker.subtitle ==
            "Auto tries Antigravity app, agy CLI, then IDE; OAuth follows for selected or signed-in accounts.")
    }

    @Test
    func `antigravity exhausted five hour and weekly priority names both surfaces and persists across reopen`() throws {
        let suite = "ProviderSettingsDescriptorTests-antigravity-ranking"
        let fixture = try self.makeSettingsFixture(suite: suite)
        let context = fixture.settingsContext(provider: .antigravity)

        let toggles = AntigravityProviderImplementation().settingsToggles(context: context)
        let toggle = try #require(toggles.first { $0.id == "antigravity-prioritize-exhausted-quotas" })

        #expect(toggle.title == "Prioritize exhausted quotas")
        #expect(toggle.subtitle ==
            "Optional. In Automatic mode, let exhausted five-hour or weekly lanes outrank still-usable model " +
            "families. Applies to the menu bar and Overview ranking.")
        #expect(toggle.binding.wrappedValue == false)
        #expect(fixture.settings.providerConfig(for: .antigravity)?.antigravityPrioritizeExhaustedQuotas == nil)

        toggle.binding.wrappedValue = true

        #expect(fixture.settings.antigravityPrioritizeExhaustedQuotas)
        #expect(fixture.settings.providerConfig(for: .antigravity)?.antigravityPrioritizeExhaustedQuotas == true)

        let reopened = try SettingsStore(
            userDefaults: #require(UserDefaults(suiteName: suite)),
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(reopened.antigravityPrioritizeExhaustedQuotas)

        reopened.antigravityPrioritizeExhaustedQuotas = false
        let reopenedAfterDisabling = try SettingsStore(
            userDefaults: #require(UserDefaults(suiteName: suite)),
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(reopenedAfterDisabling.antigravityPrioritizeExhaustedQuotas == false)
    }

    @Test
    func `codex exposes open AI web extras toggle as default off opt in`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-codex-openai-toggle")
        let context = fixture.settingsContext(provider: .codex)

        let toggles = CodexProviderImplementation().settingsToggles(context: context)
        let extrasToggle = try #require(toggles.first(where: { $0.id == "codex-openai-web-extras" }))
        #expect(extrasToggle.binding.wrappedValue == false)
        #expect(extrasToggle.subtitle.contains("Optional."))
        #expect(extrasToggle.subtitle.contains("Turn this on"))

        let batterySaverToggle = try #require(toggles.first(where: { $0.id == "codex-openai-web-battery-saver" }))
        #expect(batterySaverToggle.binding.wrappedValue == false)
        #expect(batterySaverToggle.isVisible?() == false)

        fixture.settings.openAIWebAccessEnabled = true
        #expect(batterySaverToggle.isVisible?() == true)
    }

    @Test
    func `claude exposes usage and cookie pickers`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude")
        fixture.settings.debugDisableKeychainAccess = false
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let usagePicker = try #require(pickers.first(where: { $0.id == "claude-usage-source" }))
        #expect(usagePicker.placement == .connection)
        #expect(pickers.contains(where: { $0.id == "claude-cookie-source" }))
        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        #expect(!toggles.contains(where: { $0.id == "claude-peak-hours" }))
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        let optionIDs = Set(keychainPicker.options.map(\.id))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.never.rawValue))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.always.rawValue))
        #expect(keychainPicker.isEnabled?() ?? true)
    }

    @Test
    func `claude single swap account toggle persists and follows integration visibility`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-swap-single")
        let context = fixture.settingsContext(provider: .claude)
        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        let singleAccountToggle = try #require(toggles.first {
            $0.id == "claude-swap-show-single-account"
        })

        #expect(singleAccountToggle.binding.wrappedValue == false)
        #expect(singleAccountToggle.isVisible?() == false)

        fixture.settings.claudeSwapEnabled = true
        #expect(singleAccountToggle.isVisible?() == true)
        singleAccountToggle.binding.wrappedValue = true

        #expect(fixture.settings.claudeSwapShowSingleAccount)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .claude)?.claudeSwapShowSingleAccount == true)
    }

    @Test
    func `claude prompt policy picker remains visible for prompt free toggle`() throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-claude-prompt-visible-prompt-free")
        fixture.settings.debugDisableKeychainAccess = false
        fixture.settings.claudeOAuthPromptFreeCredentialsEnabled = true
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isVisible?() ?? true)
        #expect(keychainPicker.binding.wrappedValue == ClaudeOAuthKeychainPromptMode.never.rawValue)
    }

    @Test
    func `claude avoid keychain prompts toggle is disabled when global keychain disabled`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-prompt-free-disabled")
        fixture.settings.debugDisableKeychainAccess = true
        fixture.settings.claudeOAuthPromptFreeCredentialsEnabled = true
        let context = fixture.settingsContext(provider: .claude)

        let toggles = ClaudeProviderImplementation().settingsToggles(context: context)
        let promptFreeToggle = try #require(toggles.first(where: { $0.id == "claude-oauth-prompt-free-credentials" }))
        #expect(promptFreeToggle.isEnabled?() == false)
        #expect(promptFreeToggle.binding.wrappedValue == true)

        promptFreeToggle.binding.wrappedValue = false
        #expect(fixture.settings.claudeOAuthPromptFreeCredentialsEnabled == true)

        fixture.settings.debugDisableKeychainAccess = false
        #expect(promptFreeToggle.isEnabled?() == true)
        #expect(promptFreeToggle.binding.wrappedValue == true)
    }

    @Test
    func `claude keychain prompt policy picker disabled when global keychain disabled`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-keychain-disabled")
        fixture.settings.debugDisableKeychainAccess = true
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isEnabled?() == false)
        let subtitle = keychainPicker.dynamicSubtitle?() ?? ""
        #expect(subtitle.localizedCaseInsensitiveContains("inactive"))
    }

    @Test
    func `claude web extras auto disables when leaving CLI`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-invariant")
        let settings = fixture.settings
        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .cli
        settings.claudeWebExtrasEnabled = true

        settings.claudeUsageDataSource = .oauth
        #expect(settings.claudeWebExtrasEnabled == false)
    }

    @Test
    func `kilo exposes usage source picker and api field only`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-kilo")
        let context = fixture.settingsContext(provider: .kilo)

        let implementation = KiloProviderImplementation()
        let toggles = implementation.settingsToggles(context: context)
        let pickers = implementation.settingsPickers(context: context)
        let fields = implementation.settingsFields(context: context)

        #expect(toggles.isEmpty)
        #expect(pickers.contains(where: { $0.id == "kilo-usage-source" }))
        #expect(fields.contains(where: { $0.id == "kilo-api-key" }))
    }

    @Test
    func `copilot budget secondary picker appears before cookie picker`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-copilot-budget-pickers")
        fixture.settings.copilotBudgetExtrasEnabled = true
        let context = fixture.settingsContext(provider: .copilot)

        let pickers = CopilotProviderImplementation().settingsPickers(context: context)

        #expect(pickers.map(\.id) == ["copilot-icon-secondary-window", "copilot-budget-cookie-source"])
        #expect(pickers.first?.title == "Menu bar secondary metric")
        #expect(pickers.first?.placement == .menuBar)
        #expect(pickers.last?.placement == .connection)
    }

    @Test
    func `kiro menu bar display picker uses the menu bar placement`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-kiro-placement")
        let context = fixture.settingsContext(provider: .kiro)

        let pickers = KiroProviderImplementation().settingsPickers(context: context)
        let picker = try #require(pickers.first(where: { $0.id == "kiroMenuBarDisplay" }))

        #expect(picker.placement == .menuBar)
    }

    @Test
    func `copilot manual cookie field is labelled and refreshable`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-copilot-budget-field")
        fixture.settings.copilotBudgetExtrasEnabled = true
        fixture.settings.copilotBudgetCookieSource = .manual
        let context = fixture.settingsContext(provider: .copilot)

        let fields = CopilotProviderImplementation().settingsFields(context: context)
        let field = try #require(fields.first { $0.id == "copilot-budget-cookie-header" })

        #expect(field.title == "Manual GitHub Cookie header")
        #expect(field.subtitle.contains("Treat this value like a password"))
        #expect(field.actions.map(\.id) == ["refresh-copilot-budget-cookie"])
    }

    @Test
    func `kimi exposes usage source picker plus api and cookie fields`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-kimi")
        let context = fixture.settingsContext(provider: .kimi)

        let implementation = KimiProviderImplementation()
        let pickers = implementation.settingsPickers(context: context)
        let fields = implementation.settingsFields(context: context)

        let usagePicker = try #require(pickers.first(where: { $0.id == "kimi-usage-source" }))
        #expect(usagePicker.options.map(\.id) == ["auto", "api", "web"])
        #expect(usagePicker.subtitle ==
            "Auto tries your configured API key, then a signed-in Kimi Code CLI credential, then browser cookies.")
        #expect(usagePicker.placement == .connection)
        #expect(usagePicker.trailingText?() == nil)
        fixture.store.lastSourceLabels[.kimi] = "Kimi Code CLI"
        #expect(usagePicker.trailingText?() == "Kimi Code CLI")
        #expect(pickers.contains(where: { $0.id == "kimi-cookie-source" }))
        #expect(fields.contains(where: { $0.id == "kimi-api-key" }))
        #expect(fields.contains(where: { $0.id == "kimi-cookie" }))
    }

    @Test
    func `kimi presentation follows selected source label`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-kimi-presentation")
        fixture.settings.kimiUsageDataSource = .api
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.kimi])
        let context = fixture.presentationContext(provider: .kimi, metadata: metadata)

        let detailLine = KimiProviderImplementation()
            .presentation(context: context)
            .detailLine(context)

        #expect(detailLine == "api")
    }

    @Test
    func `deepgram exposes api key and project id fields`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepgram")
        let context = fixture.settingsContext(provider: .deepgram)

        let implementation = DeepgramProviderImplementation()
        let fields = implementation.settingsFields(context: context)

        #expect(fields.contains(where: { $0.id == "deepgram-api-key" }))
        #expect(fields.contains(where: { $0.id == "deepgram-project-id" }))

        // Basic presence checks for Deepgram settings fields (layout copied from OpenRouter)
        _ = try #require(fields.first(where: { $0.id == "deepgram-project-id" }))
        _ = try #require(fields.first(where: { $0.id == "deepgram-api-key" }))
    }

    @Test
    func `alibaba presentation follows store source label`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-alibaba-presentation")
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.alibaba])
        let context = fixture.presentationContext(provider: .alibaba, metadata: metadata)

        let detailLine = AlibabaCodingPlanProviderImplementation()
            .presentation(context: context)
            .detailLine(context)

        #expect(detailLine == fixture.store.sourceLabel(for: .alibaba))
    }
}

extension ProviderSettingsDescriptorTests {
    @Test
    func `devin presentation follows store source label`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-devin-presentation")
        fixture.store.lastSourceLabels[.devin] = "web"
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.devin])
        let context = fixture.presentationContext(provider: .devin, metadata: metadata)

        let detailLine = DevinProviderImplementation()
            .presentation(context: context)
            .detailLine(context)

        #expect(detailLine == "web")
    }
}

extension ProviderSettingsDescriptorTests {
    @Test
    func `alibaba token plan settings expose cookie controls`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-alibaba-token-plan-settings")
        fixture.settings.alibabaTokenPlanCookieSource = .manual
        let context = fixture.settingsContext(provider: .alibabatokenplan)
        let implementation = AlibabaTokenPlanProviderImplementation()
        let pickers = implementation.settingsPickers(context: context)
        let fields = implementation.settingsFields(context: context)

        #expect(pickers.contains(where: { $0.id == "alibaba-token-plan-cookie-source" }))
        #expect(fields.contains(where: { $0.id == "alibaba-token-plan-cookie" }))
        #expect(fields.first?.actions.contains(where: { $0.id == "alibaba-token-plan-open-dashboard" }) == true)
    }

    @Test
    func `deepseek profile picker contains only validated profiles and persists selection`() throws {
        let apiKey = "test-deepseek-api-key"
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-profiles",
            environmentBase: [DeepSeekSettingsReader.apiKeyEnvironmentKey: apiKey])
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        let context = fixture.settingsContext(provider: .deepseek)

        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Default", "chrome:Profile 2"])
        #expect(picker.binding.wrappedValue.isEmpty)
        let configRevision = fixture.settings.configRevision
        let backgroundWorkRevision = fixture.settings.backgroundWorkSettingsRevision
        let providerConfigRevision = fixture.settings.providerConfigRevision(for: .deepseek)
        let snapshot = fixture.store.snapshots[.deepseek]

        picker.binding.wrappedValue = "chrome:Profile 2"
        #expect(fixture.settings.deepseekProfileID(apiKey: apiKey) == "chrome:Profile 2")
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileID == "chrome:Profile 2")
        let expectedScope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: nil,
            apiKey: apiKey))
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileScope == expectedScope)
        #expect(fixture.settings.configRevision == configRevision)
        #expect(fixture.settings.backgroundWorkSettingsRevision == backgroundWorkRevision)
        #expect(fixture.settings.providerConfigRevision(for: .deepseek) == providerConfigRevision + 1)
        #expect(fixture.store.snapshots[.deepseek]?.updatedAt == snapshot?.updatedAt)
        #expect(fixture.store.snapshots[.deepseek]?.deepseekPlatformProfiles.map(\.id) == [
            "chrome:Default",
            "chrome:Profile 2",
        ])
    }

    @Test
    func `deepseek browser only profile selection persists without an API key`() async throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-browser-only-profile")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 (Paid: $8.06 / Granted: $0.00)"),
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())

        let picker = try #require(DeepSeekProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .deepseek)).first)
        picker.binding.wrappedValue = "chrome:Profile 2"

        #expect(fixture.settings.deepseekProfileID(apiKey: nil) == "chrome:Profile 2")
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileScope != nil)
        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Refreshing")

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(DeepSeekUsageError.networkError("offline")),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Unavailable")
        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription?.contains("$8.06") == false)
    }

    @Test
    func `deepseek profile picker stays visible while switching profiles`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-profile-switch")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        fixture.store.lastKnownResetSnapshots[.deepseek] = snapshot
        fixture.store.snapshots.removeValue(forKey: .deepseek)
        fixture.store.refreshingProviders.insert(.deepseek)
        let context = fixture.settingsContext(provider: .deepseek)

        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Default", "chrome:Profile 2"])
        #expect(picker.binding.wrappedValue.isEmpty)
        #expect(picker.dynamicSubtitle?() == "Refreshing")
        #expect(!(picker.isEnabled?() ?? true))
    }

    @Test
    func `deepseek browser profile cancellation does not leave refreshing behind`() async throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-browser-cancelled-transition")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition(preservingBalance: false)

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(result: .failure(CancellationError()), attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Unavailable")
    }

    @Test
    func `deepseek settings keeps balance while live snapshot is switching`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-balance-switch")
        fixture.store.lastKnownResetSnapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$9.32 (Paid: $9.32 / Granted: $0.00)"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.snapshots.removeValue(forKey: .deepseek)
        fixture.store.refreshingProviders.insert(.deepseek)

        let model = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .deepseek)

        let balance = try #require(model.metrics.first)
        #expect(balance.title == "Balance")
        #expect(balance.statusText == "$9.32 (Paid: $9.32 / Granted: $0.00)")
        #expect(model.usageNotes.isEmpty)
        #expect(model.inlineUsageDashboard == nil)
        #expect(model.placeholder == nil)
    }

    @Test
    func `deepseek profile transition survives selected api token cache invalidation`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-token-transition")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "cv", token: "test-token")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 (Paid: $8.06 / Granted: $0.00)"),
            secondary: nil,
            deepseekUsage: DeepSeekUsageSummary(
                todayTokens: 100,
                currentMonthTokens: 100,
                todayCost: 0.1,
                currentMonthCost: 0.1,
                requestCount: 1,
                currentMonthRequestCount: 1,
                topModel: "deepseek-chat",
                categoryBreakdown: [],
                daily: [],
                currency: "USD",
                updatedAt: Date()),
            deepseekDetailedUsageState: .available,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        fixture.store.snapshots[.deepseek] = snapshot
        fixture.store.lastKnownResetSnapshots[.deepseek] = snapshot
        let context = fixture.settingsContext(provider: .deepseek)
        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)

        picker.binding.wrappedValue = "chrome:Profile 2"
        fixture.store.refreshingProviders.insert(.deepseek)
        fixture.store.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
            provider: .deepseek,
            accounts: fixture.settings.tokenAccounts(for: .deepseek))

        #expect(fixture.store.snapshots[.deepseek] == nil)
        #expect(fixture.store.lastKnownResetSnapshots[.deepseek] == nil)
        let model = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .deepseek)
        #expect(model.metrics.first?.statusText == "$8.06 (Paid: $8.06 / Granted: $0.00)")
        #expect(model.inlineUsageDashboard == nil)
        #expect(model.usageNotes.isEmpty)
        #expect(!ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_providerSubtitle(.deepseek).contains("usage not fetched yet"))
        let transitionPicker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        #expect(transitionPicker.options.map(\.id) == ["chrome:Default", "chrome:Profile 2"])
        #expect(!(transitionPicker.isEnabled?() ?? true))

        fixture.store.refreshingProviders.remove(.deepseek)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.primary != nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.deepseekUsage == nil)

        fixture.store.clearDeepSeekProfileTransition()
        #expect(fixture.store.presentationSnapshot(for: .deepseek) == nil)
    }

    @Test
    func `deepseek selected account success clears its profile transition`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-transition-success")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()
        let refreshed = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$7.50"),
            secondary: nil,
            updatedAt: Date())

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: refreshed,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "api",
                    strategyID: "deepseek.api",
                    strategyKind: .apiToken)),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot == nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.primary?.resetDescription == "$7.50")
    }

    @Test
    func `deepseek timeout keeps the validated profile catalog with the refreshed balance`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-timeout-catalog")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            deepseekDetailedUsageState: .available,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()
        let refreshedBalance = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$7.50"),
            secondary: nil,
            deepseekDetailedUsageState: .unavailable,
            deepseekPlatformProfiles: [],
            updatedAt: Date())

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: refreshedBalance,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "api",
                    strategyID: "deepseek.api",
                    strategyKind: .apiToken)),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot == nil)
        #expect(fixture.store.snapshots[.deepseek]?.primary?.resetDescription == "$7.50")
        #expect(fixture.store.snapshots[.deepseek]?.deepseekPlatformProfiles.map(\.id) == [
            "chrome:Default",
            "chrome:Profile 2",
        ])
        let picker = try #require(DeepSeekProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .deepseek)).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Default", "chrome:Profile 2"])
    }

    @Test
    func `deepseek selected account failure preserves its balance only transition`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-transition-failure")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            deepseekUsage: DeepSeekUsageSummary(
                todayTokens: 100,
                currentMonthTokens: 100,
                todayCost: nil,
                currentMonthCost: nil,
                requestCount: 1,
                currentMonthRequestCount: 1,
                topModel: nil,
                categoryBreakdown: [],
                daily: [],
                currency: "USD",
                updatedAt: Date()),
            deepseekDetailedUsageState: .available,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()

        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(DeepSeekUsageError.apiError("offline")),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)

        #expect(fixture.store.deepseekProfileTransitionSnapshot != nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.primary?.resetDescription == "$8.06")
        #expect(fixture.store.presentationSnapshot(for: .deepseek)?.deepseekUsage == nil)
    }

    @Test
    func `disabling deepseek clears a failed profile transition`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-disable-transition")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06"),
            secondary: nil,
            updatedAt: Date())
        fixture.store.beginDeepSeekProfileTransition()
        await fixture.store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(DeepSeekUsageError.apiError("offline")),
                attempts: []),
            provider: .deepseek,
            account: nil,
            fallbackSnapshot: nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek) != nil)

        fixture.store.clearDisabledProviderState(enabledProviders: [])

        #expect(fixture.store.deepseekProfileTransitionSnapshot == nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek) == nil)
    }

    @Test
    func `deepseek requires explicit replacement when the stored profile expires`() throws {
        let apiKey = "test-deepseek-api-key"
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-deepseek-expired-selection",
            environmentBase: [DeepSeekSettingsReader.apiKeyEnvironmentKey: apiKey])
        fixture.settings.setDeepSeekProfileID("chrome:Default", apiKey: apiKey)
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekDetailedUsageState: .profileSelectionRequired,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())

        let picker = try #require(DeepSeekProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .deepseek)).first)
        #expect(picker.options.map(\.id) == ["", "chrome:Profile 2"])
        #expect(picker.binding.wrappedValue.isEmpty)
    }

    @Test
    func `deepseek profile transition does not cross api token account selection`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-account-transition")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "token-1")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "token-2")
        let workAccount = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 Work"),
            secondary: nil,
            updatedAt: Date())
        fixture.settings.setDeepSeekProfileID("chrome:Profile 2", apiKey: workAccount.token)
        fixture.store.beginDeepSeekProfileTransition()

        fixture.settings.setActiveTokenAccountIndex(0, for: .deepseek)
        let personalAccount = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        #expect(personalAccount.id != workAccount.id)
        fixture.store.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
            provider: .deepseek,
            accounts: fixture.settings.tokenAccounts(for: .deepseek))

        #expect(fixture.settings.deepseekProfileID(apiKey: personalAccount.token).isEmpty)
        #expect(fixture.store.deepseekProfileTransitionSnapshot != nil)
        #expect(fixture.store.presentationSnapshot(for: .deepseek) == nil)
    }

    @Test
    func `replacing a deepseek key in the same account clears its profile selection`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-replaced-key")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Account", token: "old-key")
        let account = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        fixture.settings.setDeepSeekProfileID("chrome:Default", apiKey: account.token)
        #expect(fixture.settings.deepseekProfileID(apiKey: account.token) == "chrome:Default")

        fixture.settings.updateTokenAccount(
            provider: .deepseek,
            accountID: account.id,
            token: "new-key")

        #expect(fixture.settings.deepseekProfileID(apiKey: "new-key").isEmpty)
        #expect(fixture.settings.providerConfig(for: .deepseek)?.sanitizedDeepSeekProfileID == "chrome:Default")
    }

    @Test
    func `deepseek detailed usage requires cost extras and active api token account`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-account-usage")
        fixture.settings.showOptionalCreditsAndExtraUsage = true
        fixture.settings.costSummaryOption = .inlineSummary
        #expect(fixture.settings.costSummaryShowsInlineDashboard(for: .deepseek))
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "token-1")
        fixture.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "token-2")
        let accounts = fixture.settings.tokenAccounts(for: .deepseek)
        let active = try #require(fixture.settings.selectedTokenAccount(for: .deepseek))
        let inactive = try #require(accounts.first(where: { $0.id != active.id }))

        #expect(ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: inactive)))
        fixture.settings.costSummaryOption = .costSubmenu
        #expect(fixture.settings.costSummaryShowsInlineDashboard(for: .deepseek))
        #expect(ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
        fixture.settings.costSummaryOption = .both
        #expect(fixture.settings.costSummaryShowsInlineDashboard(for: .deepseek))
        fixture.settings.costSummaryOption = .off
        #expect(!fixture.settings.costSummaryShowsInlineDashboard(for: .deepseek))
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
        fixture.settings.showOptionalCreditsAndExtraUsage = false
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .codex,
            settings: fixture.settings,
            override: nil))
        fixture.settings.costSummaryOption = .inlineSummary
        #expect(!ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
            provider: .deepseek,
            settings: fixture.settings,
            override: TokenAccountOverride(provider: .deepseek, account: active)))
    }

    @Test
    func `provider settings labels an empty transition as refreshing`() {
        #expect(ProviderMetricsInlineView.placeholderText(
            isEnabled: true,
            isRefreshing: true,
            modelPlaceholder: nil) == "Refreshing")
        #expect(ProviderMetricsInlineView.placeholderText(
            isEnabled: true,
            isRefreshing: false,
            modelPlaceholder: nil) == "No usage yet")
    }

    @Test
    func `deepseek hides profile picker when only one validated profile remains`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-deepseek-single-profile")
        fixture.store.snapshots[.deepseek] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
            ],
            updatedAt: Date())
        let context = fixture.settingsContext(provider: .deepseek)

        #expect(DeepSeekProviderImplementation().settingsPickers(context: context).isEmpty)
    }
}

extension ProviderSettingsDescriptorTests {
    private func makeSettingsFixture(
        suite: String,
        environmentBase: [String: String] = [:]) throws -> ProviderSettingsFixture
    {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: environmentBase)
        return ProviderSettingsFixture(settings: settings, store: store)
    }

    private struct ProviderSettingsFixture {
        let settings: SettingsStore
        let store: UsageStore
        private let state = ProviderSettingsContextState()

        @MainActor
        func settingsContext(provider: UsageProvider) -> ProviderSettingsContext {
            let settings = self.settings
            let store = self.store
            let state = self.state
            return ProviderSettingsContext(
                provider: provider,
                settings: settings,
                store: store,
                boolBinding: { keyPath in
                    Binding(
                        get: { settings[keyPath: keyPath] },
                        set: { settings[keyPath: keyPath] = $0 })
                },
                stringBinding: { keyPath in
                    Binding(
                        get: { settings[keyPath: keyPath] },
                        set: { settings[keyPath: keyPath] = $0 })
                },
                statusText: { id in state.statusByID[id] },
                setStatusText: { id, text in
                    if let text {
                        state.statusByID[id] = text
                    } else {
                        state.statusByID.removeValue(forKey: id)
                    }
                },
                lastAppActiveRunAt: { id in state.lastRunAtByID[id] },
                setLastAppActiveRunAt: { id, date in
                    if let date {
                        state.lastRunAtByID[id] = date
                    } else {
                        state.lastRunAtByID.removeValue(forKey: id)
                    }
                },
                requestConfirmation: { _ in },
                runLoginFlow: {})
        }

        @MainActor
        func presentationContext(provider: UsageProvider, metadata: ProviderMetadata) -> ProviderPresentationContext {
            ProviderPresentationContext(
                provider: provider,
                settings: self.settings,
                store: self.store,
                metadata: metadata)
        }
    }

    private final class ProviderSettingsContextState {
        var statusByID: [String: String] = [:]
        var lastRunAtByID: [String: Date] = [:]
    }
}

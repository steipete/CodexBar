import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
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
    func `codex exposes usage and cookie pickers`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-codex")
        let context = fixture.settingsContext(provider: .codex)

        let pickers = CodexProviderImplementation().settingsPickers(context: context)
        let toggles = CodexProviderImplementation().settingsToggles(context: context)
        #expect(pickers.contains(where: { $0.id == "codex-usage-source" }))
        #expect(pickers.contains(where: { $0.id == "codex-cookie-source" }))
        #expect(toggles.contains(where: { $0.id == "codex-historical-tracking" }))
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
        #expect(pickers.contains(where: { $0.id == "claude-usage-source" }))
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
    func `claude prompt policy picker hidden when experimental reader selected`() throws {
        let fixture = try self.makeSettingsFixture(
            suite: "ProviderSettingsDescriptorTests-claude-prompt-hidden-experimental")
        fixture.settings.debugDisableKeychainAccess = false
        fixture.settings.claudeOAuthKeychainReadStrategy = .securityCLIExperimental
        let context = fixture.settingsContext(provider: .claude)

        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isVisible?() == false)
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

    private func makeSettingsFixture(suite: String) throws -> ProviderSettingsFixture {
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
            settings: settings)
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
